local CanvasContext = require("document/canvascontext")
local Document = require("document/document")
local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local C_ = _.pgettext

local Spread = require("mupdftwopage/spread")

-- Other plugins call the class slot directly; that call must stay one page.
if not Document._mupdftwopage_render_shim then
    Document._mupdftwopage_render_shim = true
    local base_document_render_page = Document.renderPage
    function Document.renderPage(doc, pageno, rect, zoom, rotation, ...)
        if doc._mupdftwopage_installed then
            -- Not doc:renderPage: koptinterface reaches this slot from there.
            return doc:_mupdftwopageWithSingle(base_document_render_page, doc,
                pageno, rect, zoom, rotation, ...)
        end
        return base_document_render_page(doc, pageno, rect, zoom, rotation, ...)
    end
end

local MODE_OFF, MODE_AUTO, MODE_ON = "off", "auto", "on"

-- The config panel is process-wide, so its rows must not hold a closed book.
local current = nil

local MuPdfTwoPage = WidgetContainer:extend{
    name = "mupdftwopage",
    is_doc_only = true,
}

local function isPairModeValue(value)
    return value == MODE_OFF or value == MODE_AUTO or value == MODE_ON
end

local function isOn(value)
    return value == 1 or value == "1" or value == true
end

local function isOne(value)
    return tonumber(value) == 1
end

local function screenSize()
    local canvas = CanvasContext:getSize()
    if canvas and canvas.w and canvas.h and canvas.w > 0 and canvas.h > 0 then
        return { w = canvas.w, h = canvas.h }
    end
    return { w = Screen:getWidth(), h = Screen:getHeight() }
end

function MuPdfTwoPage:init()
    local doc = self.document
    local paging = self.ui and self.ui.paging
    if not (doc and paging and doc.provider == "mupdf"
        and doc.is_reflowable ~= true
        and doc.info and doc.info.has_pages) then
        return
    end
    local configurable = doc.configurable
    if not configurable or doc._mupdftwopage_installed then
        return
    end
    doc._mupdftwopage_installed = true
    current = self

    -- Read before ReadSettings: paging restores last_page during that event.
    local settings = self.ui.doc_settings
    local function bookSetting(key)
        local value = settings and settings:readSetting(key)
        if value == nil then
            return G_reader_settings:readSetting(key)
        end
        return value
    end
    local mode = bookSetting("kopt_twopage")
    configurable.twopage = isPairModeValue(mode) and mode or MODE_OFF
    -- The anchor names a page, so it is never a default for another book.
    local offset = settings and settings:readSetting("kopt_twopage_offset")
    configurable.twopage_offset = tonumber(offset) or 0
    local gutter = bookSetting("kopt_twopage_gutter")
    configurable.twopage_gutter = gutter == nil and 1 or (isOn(gutter) and 1 or 0)
    -- The two stock answers the pair depends on are read before they are loaded.
    local scroll = bookSetting("kopt_page_scroll")
    if scroll ~= nil then
        configurable.page_scroll = scroll
    end
    local wrap = bookSetting("kopt_text_wrap")
    if wrap ~= nil then
        configurable.text_wrap = wrap
    end

    self:installDocument(doc)
    self:installZooming()
    self:installPaging(paging)
    self:installView()
    self:addOptions()

    self._mupdftwopage_active = doc:_mupdftwopageActive()
    logger.info("MuPDFTwoPages: ready; mode =", configurable.twopage,
        "; offset =", configurable.twopage_offset,
        "; gutter =", configurable.twopage_gutter)
end

function MuPdfTwoPage:installDocument(doc)
    local plugin = self
    local orig_native = doc.getNativePageDimensions
    local orig_dimensions = doc.getPageDimensions
    local orig_used_bbox = doc.getUsedBBoxDimensions
    local orig_render = doc.renderPage
    local orig_draw = doc.drawPage

    doc._mupdftwopage_dims = {}
    doc._mupdftwopage_single = false
    doc._mupdftwopage_zoom_pair = false
    doc._mupdftwopage_layout_busy = false

    local function pageDims(doc_self, pageno)
        local dims = doc_self._mupdftwopage_dims[pageno]
        if dims then
            return dims
        end
        local geom = orig_native(doc_self, pageno)
        dims = { w = geom and geom.w or 1, h = geom and geom.h or 1 }
        doc_self._mupdftwopage_dims[pageno] = dims
        return dims
    end

    local function pageBox(doc_self, pageno)
        local geom = pageDims(doc_self, pageno)
        local full = { x = 0, y = 0, w = geom.w, h = geom.h }
        local c = doc_self.configurable
        -- "Page Crop: none" never consults getPageBBox; neither may the pair.
        if c and tonumber(c.trim_page) == 3 then
            return full
        end
        local bbox = doc_self:getPageBBox(pageno)
        if not (bbox and bbox.x1 and bbox.y1) then
            return full
        end
        local x0 = math.max(0, tonumber(bbox.x0) or 0)
        local y0 = math.max(0, tonumber(bbox.y0) or 0)
        local x1 = math.min(geom.w, tonumber(bbox.x1) or geom.w)
        local y1 = math.min(geom.h, tonumber(bbox.y1) or geom.h)
        if x1 <= x0 or y1 <= y0 then
            return full
        end
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end

    local function wideList(doc_self)
        local count = doc_self.info and doc_self.info.number_of_pages or 0
        if doc_self._mupdftwopage_wide and doc_self._mupdftwopage_wide_count == count then
            return doc_self._mupdftwopage_wide
        end
        local list = {}
        for p = 1, count do
            local dims = pageDims(doc_self, p)
            if dims.w > dims.h then
                list[#list + 1] = p
            end
        end
        doc_self._mupdftwopage_wide = list
        doc_self._mupdftwopage_wide_count = count
        return list
    end

    local function anchor(doc_self)
        local value = doc_self.configurable and doc_self.configurable.twopage_offset
        if value == true then
            return 1
        end
        local page = tonumber(value)
        if not page or page < 1 then
            return 0
        end
        return math.floor(page)
    end

    local function active(doc_self)
        local c = doc_self.configurable
        local value = c and c.twopage
        if not isPairModeValue(value) then
            return false
        end
        if isOne(c.text_wrap) or isOne(c.page_scroll) then
            return false
        end
        local view = plugin.ui and plugin.ui.view
        if view and view.page_scroll then
            return false
        end
        if value == MODE_ON then
            return true
        end
        if value == MODE_OFF then
            return false
        end
        -- A natural-landscape tablet sits at mode 0 in landscape.
        return Screen:getWidth() > Screen:getHeight()
    end

    local function pairFor(doc_self, pageno)
        if not active(doc_self) then
            return nil
        end
        local count = doc_self.info and doc_self.info.number_of_pages
        if not (count and pageno and pageno >= 1 and pageno <= count) then
            return nil
        end
        return Spread.unitFor(pageno, count, wideList(doc_self), anchor(doc_self))
    end

    local function sides(doc_self, pair)
        local view = plugin.ui and plugin.ui.view
        if view and view.inverse_reading_order then
            return pair.b, pair.a
        end
        return pair.a, pair.b
    end

    local function fitsByWidth(doc_self)
        local c = doc_self.configurable
        local genus = c and tonumber(c.zoom_mode_genus)
        local kind = c and tonumber(c.zoom_mode_type)
        return not (genus == 3 and (kind == 2 or kind == 0))
    end

    local function layoutFor(doc_self, pair)
        if not pair or not pair.b or doc_self._mupdftwopage_layout_busy then
            return nil
        end
        -- getPageBBox may analyze a page and ask for its size; one layout at a time.
        doc_self._mupdftwopage_layout_busy = true
        local ok, layout = pcall(function()
            local left_page, right_page = sides(doc_self, pair)
            local l = pageBox(doc_self, left_page)
            local r = pageBox(doc_self, right_page)
            local screen = screenSize()

            local scales = Spread.grow(l.w, l.h, r.w, r.h,
                screen.w, screen.h, fitsByWidth(doc_self))

            local gutter = { left = 0, right = 0 }
            local c = doc_self.configurable
            local gutter_on = c == nil or c.twopage_gutter == nil or isOn(c.twopage_gutter)
            if gutter_on then
                local sl, sr = scales.left, scales.right
                local left_dims = pageDims(doc_self, left_page)
                local paper = Spread.gutter(
                    l.w * sl + r.w * sr,
                    math.max(l.h * sl, r.h * sr),
                    math.max(0, left_dims.w - (l.x + l.w)) * sl,
                    math.max(0, r.x) * sr,
                    screen.w, screen.h)
                gutter = { left = paper.left / sl, right = paper.right / sr }
            end

            local left = { x = l.x, y = l.y, w = l.w + gutter.left, h = l.h }
            local right = { x = r.x - gutter.right, y = r.y, w = r.w + gutter.right, h = r.h }

            return {
                left = { page = left_page, box = left, scale = scales.left },
                right = { page = right_page, box = right, scale = scales.right },
                w = left.w * scales.left + right.w * scales.right,
                h = math.max(left.h * scales.left, right.h * scales.right),
            }
        end)
        doc_self._mupdftwopage_layout_busy = false
        if not ok then
            error(layout, 0)
        end
        return layout
    end

    local function pairGeom(doc_self, pair)
        local layout = layoutFor(doc_self, pair)
        if not layout then
            return nil
        end
        return Geom:new{ x = 0, y = 0, w = layout.w, h = layout.h }
    end

    local function pairFullGeom(doc_self, pair)
        local layout = layoutFor(doc_self, pair)
        if not layout then
            return nil
        end
        local a = pageDims(doc_self, layout.left.page)
        local b = pageDims(doc_self, layout.right.page)
        return {
            w = a.w * layout.left.scale + b.w * layout.right.scale,
            h = math.max(a.h * layout.left.scale, b.h * layout.right.scale),
        }
    end

    doc._mupdftwopageActive = active
    doc._mupdftwopagePair = pairFor
    doc._mupdftwopageLayout = layoutFor

    function doc:_mupdftwopageOffsetHere(pageno)
        local page = anchor(self)
        if page <= 0 then
            return false
        end
        local list = wideList(self)
        return Spread.runStart(page, list) == Spread.runStart(pageno or 0, list)
    end

    -- The fit asks for the pair only while its own zoom is being computed.
    doc.getNativePageDimensions = function(doc_self, pageno)
        if doc_self._mupdftwopage_zoom_pair and not doc_self._mupdftwopage_single then
            local pair = pairFor(doc_self, pageno)
            if pair and pair.b then
                local full = pairFullGeom(doc_self, pair)
                if full then
                    -- A fractional ceiling can be a hair under the crop box.
                    return Geom:new{ w = math.ceil(full.w), h = math.ceil(full.h) }
                end
            end
        end
        return orig_native(doc_self, pageno)
    end

    doc.getPageDimensions = function(doc_self, pageno, zoom, rotation)
        if not doc_self._mupdftwopage_single then
            local pair = pairFor(doc_self, pageno)
            if pair and pair.b then
                local geom = pairGeom(doc_self, pair)
                if geom then
                    return doc_self:transformRect(geom, zoom or 1, rotation or 0)
                end
            end
        end
        return orig_dimensions(doc_self, pageno, zoom, rotation)
    end

    doc.getUsedBBoxDimensions = function(doc_self, pageno, zoom, rotation)
        if not doc_self._mupdftwopage_single then
            local pair = pairFor(doc_self, pageno)
            if pair and pair.b then
                local geom = pairGeom(doc_self, pair)
                if geom then
                    return doc_self:transformRect(geom, zoom or 1, rotation or 0)
                end
            end
        end
        return orig_used_bbox(doc_self, pageno, zoom, rotation)
    end

    -- Single pages inside a pair: the flag keeps the pair geometry out of them.
    function doc:_mupdftwopageWithSingle(fn, ...)
        local prev = self._mupdftwopage_single
        self._mupdftwopage_single = true
        local ok, a, b, c, d = pcall(fn, ...)
        self._mupdftwopage_single = prev
        if not ok then
            error(a, 0)
        end
        return a, b, c, d
    end

    doc.renderPage = function(doc_self, pageno, rect, zoom, rotation, gamma, saturation, hinting)
        return doc_self:_mupdftwopageWithSingle(orig_render, doc_self,
            pageno, rect, zoom, rotation, gamma, saturation, hinting)
    end

    function doc:_mupdftwopagePointAt(pair, x, y)
        local layout = layoutFor(self, pair)
        if not layout then
            return pair.a, x, y, 1
        end
        local view = plugin.ui and plugin.ui.view
        local zoom = view and view.state and view.state.zoom or 1
        local left, right = layout.left, layout.right
        -- x and y are pair coordinates in the pages' own units.
        local seam = left.box.w * left.scale
        if x >= seam then
            return right.page,
                (x - seam) / right.scale + right.box.x,
                y / right.scale + right.box.y,
                zoom * right.scale
        end
        return left.page,
            x / left.scale + left.box.x,
            y / left.scale + left.box.y,
            zoom * left.scale
    end

    function doc:_mupdftwopagePageRectToScreen(pair, page, rect)
        local layout = layoutFor(self, pair)
        if not layout then
            return nil
        end
        local view = plugin.ui and plugin.ui.view
        local zoom = view and view.state and view.state.zoom or 1
        local left, right = layout.left, layout.right
        local side
        local origin
        if page == left.page then
            side = left
            origin = 0
        elseif page == right.page then
            side = right
            origin = left.box.w * zoom * left.scale
        else
            return nil
        end
        local side_zoom = zoom * side.scale
        local trans = Geom:new{
            x = origin + (rect.x - side.box.x) * side_zoom,
            y = (rect.y - side.box.y) * side_zoom,
            w = rect.w * side_zoom,
            h = rect.h * side_zoom,
        }
        if not view or not view.visible_area:intersectWith(trans) then
            return nil
        end
        return Geom:new{
            x = view.state.offset.x + trans.x - view.visible_area.x,
            y = view.state.offset.y + trans.y - view.visible_area.y,
            w = trans.w,
            h = trans.h,
        }
    end

    function doc:_mupdftwopageSnap(number, current_page, turn)
        if not active(self) then
            return number, false
        end
        local count = self.info and self.info.number_of_pages
        number = math.floor(tonumber(number) or 0)
        current_page = tonumber(current_page) or 0
        if number < 1 then
            return number, false
        end
        if count and number > count then
            number = count
        end
        local list = wideList(self)
        local page_anchor = anchor(self)
        local here = pairFor(self, current_page)
        local there = pairFor(self, number)
        if turn and here and there and here.a == there.a and current_page ~= number then
            local target
            if number >= current_page then
                target = Spread.nextStart(current_page, count, list, page_anchor)
            else
                target = Spread.prevStart(current_page, count, list, page_anchor)
            end
            if target then
                return target, false
            end
            return current_page, number >= current_page
        end
        return (there and there.a) or number, false
    end

    doc.drawPage = function(doc_self, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
        local pair = rect and pairFor(doc_self, pageno) or nil
        if not (pair and pair.b) then
            return doc_self:_mupdftwopageWithSingle(orig_draw, doc_self,
                target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
        end

        local layout = layoutFor(doc_self, pair)
        if not layout then
            return doc_self:_mupdftwopageWithSingle(orig_draw, doc_self,
                target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
        end
        local safe_zoom = (zoom and zoom > 0) and zoom or 1
        local left, right = layout.left, layout.right
        local left_zoom = safe_zoom * left.scale
        local right_zoom = safe_zoom * right.scale
        local seam = left.box.w * left_zoom
        local x0, x1 = rect.x, rect.x + rect.w
        local view = plugin.ui and plugin.ui.view
        local background = view and view.page_bgcolor or Blitbuffer.COLOR_WHITE
        -- A shorter page leaves paper below it; the previous frame was there.
        target:paintRect(x, y, rect.w, rect.h, background)

        local function half(page, box, half_zoom, origin, from, to)
            local width = to - from
            if width <= 0 then
                return
            end
            local bottom = math.min(rect.y + rect.h, box.h * half_zoom)
            local height = bottom - rect.y
            if height <= 0 then
                return
            end
            local src = Geom:new{
                x = (from - origin) + box.x * half_zoom,
                y = rect.y + box.y * half_zoom,
                w = width,
                h = height,
            }
            doc_self:_mupdftwopageWithSingle(orig_draw, doc_self,
                target, x + (from - x0), y, src, page,
                half_zoom, rotation, gamma, saturation)
        end

        half(left.page, left.box, left_zoom, 0, x0, math.min(x1, seam))
        half(right.page, right.box, right_zoom, seam, math.max(x0, seam), x1)
    end
end

function MuPdfTwoPage:installZooming()
    local zooming = self.ui and self.ui.zooming
    if not zooming or zooming._mupdftwopage_patched then
        return
    end
    zooming._mupdftwopage_patched = true
    local orig_get_zoom = zooming.getZoom
    zooming.getZoom = function(z, pageno)
        local doc = z.ui and z.ui.document
        if not (doc and doc._mupdftwopage_installed) then
            return orig_get_zoom(z, pageno)
        end
        local prev = doc._mupdftwopage_zoom_pair
        doc._mupdftwopage_zoom_pair = true
        local ok, zoom, zoom_w, zoom_h = pcall(orig_get_zoom, z, pageno)
        doc._mupdftwopage_zoom_pair = prev
        if not ok then
            error(zoom, 0)
        end
        return zoom, zoom_w, zoom_h
    end
end

function MuPdfTwoPage:installPaging(paging)
    if paging._mupdftwopage_patched then
        return
    end
    paging._mupdftwopage_patched = true
    local plugin = self

    -- Marks the two callers that mean a turn; everything else is a landing.
    local function marked(orig)
        return function(pg, ...)
            paging._mupdftwopage_turn = true
            local ok, a, b = pcall(orig, pg, ...)
            paging._mupdftwopage_turn = nil
            if not ok then
                error(a, 0)
            end
            return a, b
        end
    end
    if type(paging.onGotoPageRel) == "function" then
        paging.onGotoPageRel = marked(paging.onGotoPageRel)
    end
    if type(paging.pageFlipping) == "function" then
        paging.pageFlipping = marked(paging.pageFlipping)
    end

    local orig_goto = paging._gotoPage
    paging._gotoPage = function(pg, number, orig_mode)
        local doc = plugin.document
        if number ~= nil and doc and doc._mupdftwopage_installed then
            local turn = paging._mupdftwopage_turn
            paging._mupdftwopage_turn = nil
            local target, finished = doc:_mupdftwopageSnap(number, pg.current_page, turn)
            if finished then
                plugin.ui:handleEvent(Event:new("EndOfBook"))
                return true
            end
            if target ~= nil then
                number = target
            end
        end
        return orig_goto(pg, number, orig_mode)
    end

    if type(paging.onReflowUpdated) == "function" then
        local orig_reflow = paging.onReflowUpdated
        paging.onReflowUpdated = function(pg, ...)
            local ret = orig_reflow(pg, ...)
            plugin:syncPair()
            return ret
        end
    end
end

function MuPdfTwoPage:installView()
    local view = self.ui and self.ui.view
    if not view or view._mupdftwopage_patched then
        return
    end
    view._mupdftwopage_patched = true
    local plugin = self

    local orig_position = view.getSinglePagePosition
    view.getSinglePagePosition = function(vw, pos)
        local p = orig_position(vw, pos)
        local doc = plugin.document
        if not (p and doc and doc._mupdftwopage_installed) then
            return p
        end
        if vw.page_scroll then
            return p
        end
        local pair = doc:_mupdftwopagePair(p.page)
        if not (pair and pair.b) then
            return p
        end
        local page, x, y, zoom = doc:_mupdftwopagePointAt(pair, p.x, p.y)
        p.page, p.x, p.y, p.zoom = page, x, y, zoom
        return p
    end

    local orig_rect = view.pageToScreenTransform
    view.pageToScreenTransform = function(vw, page, rect)
        local doc = plugin.document
        if doc and doc._mupdftwopage_installed and not vw.page_scroll then
            local pair = doc:_mupdftwopagePair(vw.state.page)
            if pair and pair.b then
                return doc:_mupdftwopagePageRectToScreen(pair, page, rect)
            end
        end
        return orig_rect(vw, page, rect)
    end

    local orig_area = view.getScreenPageArea
    view.getScreenPageArea = function(vw, page)
        local doc = plugin.document
        if doc and doc._mupdftwopage_installed and not vw.page_scroll then
            local pair = doc:_mupdftwopagePair(vw.state.page)
            if pair and pair.b then
                local layout = doc:_mupdftwopageLayout(pair)
                if layout then
                    local zoom = (vw.state and vw.state.zoom) or 1
                    local left = layout.left
                    local seam = left.box.w * zoom * left.scale
                    local side
                    local origin
                    if page == left.page then
                        side = left
                        origin = 0
                    elseif page == layout.right.page then
                        side = layout.right
                        origin = seam
                    end
                    if side then
                        return Geom:new{
                            x = vw.state.offset.x + origin - vw.visible_area.x,
                            y = vw.state.offset.y - vw.visible_area.y,
                            w = side.box.w * zoom * side.scale,
                            h = side.box.h * zoom * side.scale,
                        }
                    end
                end
            end
        end
        return orig_area(vw, page)
    end

    local orig_pages = view.getCurrentPageList
    view.getCurrentPageList = function(vw)
        local doc = plugin.document
        if doc and doc._mupdftwopage_installed and not vw.page_scroll then
            local pair = doc:_mupdftwopagePair(vw.state.page)
            if pair and pair.b then
                return { pair.a, pair.b }
            end
        end
        return orig_pages(vw)
    end

    local orig_rotate = view.rotate
    view.rotate = function(vw, ...)
        local ret = orig_rotate(vw, ...)
        plugin:syncPair()
        return ret
    end

    local orig_scroll = view.onSetScrollMode
    view.onSetScrollMode = function(vw, page_scroll)
        local ret = orig_scroll(vw, page_scroll)
        plugin:syncPair()
        return ret
    end

    local orig_order = view.onToggleReadingOrder
    view.onToggleReadingOrder = function(vw, toggle)
        local ret = orig_order(vw, toggle)
        plugin:relayout()
        return ret
    end
end

function MuPdfTwoPage:syncPair()
    local doc = self.document
    if not (doc and doc._mupdftwopage_installed) then
        return
    end
    local active = doc:_mupdftwopageActive()
    local changed = active ~= self._mupdftwopage_active
    self._mupdftwopage_active = active
    if changed then
        self:relayout()
    end
end

function MuPdfTwoPage:normalizePage()
    local doc = self.document
    local paging = self.ui and self.ui.paging
    if not (doc and paging and doc._mupdftwopage_installed) then
        return
    end
    local page = paging.current_page
    local pair = doc:_mupdftwopagePair(page)
    if pair and pair.b and pair.a ~= page and type(paging._gotoPage) == "function" then
        paging:_gotoPage(pair.a)
    end
end

function MuPdfTwoPage:relayout()
    local doc = self.document
    if not (doc and doc._mupdftwopage_installed) then
        return
    end
    self._mupdftwopage_active = doc:_mupdftwopageActive()
    self:normalizePage()
    if type(self.ui.handleEvent) == "function" then
        self.ui:handleEvent(Event:new("ReZoom"))
    end
end

function MuPdfTwoPage:onReaderReady()
    if not (self.document and self.document._mupdftwopage_installed) then
        return
    end
    local was = self._mupdftwopage_active
    local active = self.document:_mupdftwopageActive()
    self._mupdftwopage_active = active
    self:normalizePage()
    if active or was then
        self.ui:handleEvent(Event:new("ReZoom"))
    end
end

function MuPdfTwoPage:onCloseDocument()
    if current == self then
        current = nil
        self:removeOptions()
    end
end

MuPdfTwoPage.onClose = MuPdfTwoPage.onCloseDocument

local function isRowEnabled(configurable)
    local plugin = current
    local doc = plugin and plugin.document
    return doc and doc._mupdftwopage_installed
        and configurable and not isOne(configurable.text_wrap)
end

local function optionRows()
    local function offsetShown()
        -- `current`, not a captured plugin: the panel outlives the book.
        local plugin = current
        local doc = plugin and plugin.document
        local page = plugin and plugin.ui and plugin.ui.paging
            and plugin.ui.paging.current_page
        if doc and doc._mupdftwopage_installed and page and doc:_mupdftwopageActive() then
            return doc:_mupdftwopageOffsetHere(page) and 1 or 0
        end
        return 0
    end

    return {
        {
            name = "twopage",
            name_text = _("Two pages"),
            toggle = {
                C_("Two pages", "off"),
                C_("Two pages", "in landscape"),
                C_("Two pages", "always"),
            },
            values = { MODE_OFF, MODE_AUTO, MODE_ON },
            args = { MODE_OFF, MODE_AUTO, MODE_ON },
            default_value = MODE_OFF,
            event = "MuPdfTwoPageModeUpdate",
            name_text_hold_callback = require("ui/data/optionsutil").showValues,
            enabled_func = function(configurable)
                return isRowEnabled(configurable)
            end,
            help_text = _([[Shows two pages side by side, the way a printed book falls open. "in landscape" does it only while the screen is turned on its side, "always" in either orientation. A page that is wider than tall is shown whole and on its own, and the pairing starts again after it.

Only in page view, not in continuous view or with Reflow.]]),
        },
        {
            name = "twopage_offset",
            name_text = _("Pair offset"),
            toggle = {
                C_("Pair offset", "off"),
                C_("Pair offset", "on"),
            },
            values = { 0, 1 },
            args = { 0, 1 },
            default_value = 0,
            event = "MuPdfTwoPageOffsetUpdate",
            current_func = offsetShown,
            enabled_func = function(configurable)
                return isRowEnabled(configurable)
                    and configurable.twopage ~= nil
                    and configurable.twopage ~= MODE_OFF
            end,
            help_text = _([[Shifts the pairs of the run you are reading one page back: off pairs 1+2, 3+4; on leaves the run's first page alone and pairs 2+3, 4+5. Setting it anchors the offset at the page on screen, and a wide page ends it by itself. Turn it on for a book whose spreads read one page out.]]),
        },
        {
            name = "twopage_gutter",
            name_text = _("Flexible gutter"),
            toggle = {
                C_("Flexible gutter", "off"),
                C_("Flexible gutter", "on"),
            },
            values = { 0, 1 },
            args = { 0, 1 },
            default_value = 1,
            event = "MuPdfTwoPageGutterUpdate",
            name_text_hold_callback = require("ui/data/optionsutil").showValues,
            enabled_func = function(configurable)
                return isRowEnabled(configurable)
                    and configurable.twopage ~= nil
                    and configurable.twopage ~= MODE_OFF
            end,
            help_text = _([[The page crop trims each page's inner margin, which would butt the two pages together at the middle. With this on, the space left over after the pages are fitted goes back into that gutter, up to the margin the page itself had and never enough to make the artwork smaller.]]),
        },
    }
end

function MuPdfTwoPage:addOptions()
    local ok, KoptOptions = pcall(require, "ui/data/koptoptions")
    if not ok or type(KoptOptions) ~= "table" then
        return
    end
    local rows = optionRows()
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.pageview" then
            local names = {}
            for _, option in ipairs(tab.options) do
                names[option.name] = true
            end
            local insert_at = #tab.options
            for i, option in ipairs(tab.options) do
                if option.name == "page_scroll" then
                    insert_at = i
                    break
                end
            end
            for i = #rows, 1, -1 do
                local row = rows[i]
                if not names[row.name] then
                    table.insert(tab.options, insert_at + 1, row)
                end
            end
            return
        end
    end
end

function MuPdfTwoPage:removeOptions()
    local ok, KoptOptions = pcall(require, "ui/data/koptoptions")
    if not ok or type(KoptOptions) ~= "table" then
        return
    end
    local names = {
        twopage = true,
        twopage_offset = true,
        twopage_gutter = true,
    }
    for _, tab in ipairs(KoptOptions) do
        if tab.icon == "appbar.pageview" then
            for i = #tab.options, 1, -1 do
                if names[tab.options[i].name] then
                    table.remove(tab.options, i)
                end
            end
            return
        end
    end
end

-- Persist at once: the bottom menu is long-lived and may not reach onClose.
function MuPdfTwoPage:save(key, value)
    local settings = self.ui and self.ui.doc_settings
    if settings then
        settings:saveSetting(key, value)
        settings:flush()
    end
end

function MuPdfTwoPage:onMuPdfTwoPageModeUpdate(value)
    local doc = self.document
    if not (doc and doc._mupdftwopage_installed) then
        return false
    end
    if not isPairModeValue(value) then
        return false
    end
    doc.configurable.twopage = value
    self:save("kopt_twopage", value)
    self:relayout()
    return true
end

function MuPdfTwoPage:onMuPdfTwoPageOffsetUpdate(value)
    local doc = self.document
    if not (doc and doc._mupdftwopage_installed) then
        return false
    end
    local anchor = 0
    if isOn(value) and doc:_mupdftwopageActive() then
        local paging = self.ui and self.ui.paging
        local page = paging and paging.current_page
        local pair = page and doc:_mupdftwopagePair(page)
        anchor = pair and pair.a or page or 0
    end
    doc.configurable.twopage_offset = anchor
    self:save("kopt_twopage_offset", anchor)
    self:relayout()
    return true
end

function MuPdfTwoPage:onMuPdfTwoPageGutterUpdate(value)
    local doc = self.document
    if not (doc and doc._mupdftwopage_installed) then
        return false
    end
    local gutter = isOn(value) and 1 or 0
    doc.configurable.twopage_gutter = gutter
    self:save("kopt_twopage_gutter", gutter)
    self:relayout()
    return true
end

return MuPdfTwoPage
