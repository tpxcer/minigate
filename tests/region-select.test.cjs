const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const lua = process.env.MINIGATE_TEST_LUA;
const root = path.resolve(__dirname, '..');
const template = path.join(root, 'luasrc/view/minigate/region_select.htm');
const proxyPage = path.join(root, 'luasrc/model/cbi/minigate/proxy.lua');
const regions = path.join(root, 'root/usr/lib/minigate/geo/regions.txt');

// 最小的 LuCI 模板解释器：只支持本模板用到的 <% %>、<%= %> 和 <%+ %>（include 输出占位）
const renderer = `
local function compile(src)
    local code, pos = {"local _o = {}\\nlocal function _w(v) _o[#_o + 1] = tostring(v) end\\n"}, 1
    while true do
        local s, e = src:find("<%", pos, true)
        local text = src:sub(pos, (s or 0) - 1)
        if s == nil then text = src:sub(pos) end
        code[#code + 1] = "_w(" .. string.format("%q", text) .. ")\\n"
        if not s then break end
        local close = assert(src:find("%>", e + 1, true), "unclosed tag")
        local body = src:sub(e + 1, close - 1)
        local mode = body:sub(1, 1)
        if mode == "=" then
            code[#code + 1] = "_w(" .. body:sub(2) .. ")\\n"
        elseif mode == "+" then
            code[#code + 1] = "_w('<!--include " .. body:sub(2):gsub("%s", "") .. "-->')\\n"
        else
            code[#code + 1] = body .. "\\n"
        end
        pos = close + 2
    end
    code[#code + 1] = "return table.concat(_o)"
    return table.concat(code)
end

function render_template(file, scope)
    local f = assert(io.open(file)); local src = f:read("*a"); f:close()
    local fn = assert(loadstring(compile(src), file))
    setfenv(fn, setmetatable(scope, {__index = _G}))
    return fn()
end

function pcdata(v)
    return (tostring(v or ""):gsub("[&<>\\"']", {["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&#39;"}))
end
`;

// 用 proxy.lua 生成真实的 option（分组、选项、cfgvalue），再渲染模板
const pageLoader = `
local options, stored = {}, nil
local function node()
    local n = {}
    function n:option(kind, name)
        local o = {kind=kind, name=name, keylist={}, vallist={}}
        function o:value(k, v) self.keylist[#self.keylist + 1] = k; self.vallist[#self.vallist + 1] = v or k end
        function o:depends() end
        options[name] = o
        return o
    end
    return n
end
function Map()
    local m = node()
    m.uci = {get=function() return stored end}
    function m:section() return node() end
    return m
end
for _, name in ipairs({'Flag','Value','DynamicList','ListValue','DummyValue','MultiValue','NamedSection','TypedSection','SimpleSection'}) do _G[name] = name end
package.preload['luci.model.uci'] = function() return {cursor=function() return {foreach=function() end, get=function() return nil end} end} end
package.preload['luci.controller.minigate'] = function() return {ddns_state=function() return {} end} end
local real_open = io.open
io.open = function(file, mode)
    if file == '/usr/lib/minigate/geo/regions.txt' then file = ${JSON.stringify(regions)} end
    return real_open(file, mode)
end
assert(dofile(${JSON.stringify(proxyPage)}))
local o = options.access_regions
function render_regions(value)
    stored = value
    return render_template(${JSON.stringify(template)}, {self=o, section='global', cbid='cbid.minigate.global.access_regions'})
end
`;

function run(body) {
    const result = spawnSync(lua, ['-'], { encoding: 'utf8', input: renderer + pageLoader + body });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout;
}

test('region selector renders 34 native checkboxes grouped by region with saved choices checked', { skip: !lua }, () => {
    const html = run(`io.write(render_regions({'510000', '500000'}))`);
    const boxes = html.match(/<input type="checkbox" class="cbi-input-checkbox" name="cbid\.minigate\.global\.access_regions" value="\d{6}"[^>]*>/g) || [];
    assert.equal(boxes.length, 34);
    const checked = boxes.filter(box => box.includes('checked="checked"')).map(box => box.match(/value="(\d+)"/)[1]);
    assert.deepEqual(checked.sort(), ['500000', '510000']);
    const groups = [...html.matchAll(/data-group="([^"]+)"/g)].map(match => match[1]);
    assert.deepEqual(groups, ['华北', '东北', '华东', '华中', '华南', '西南', '西北', '港澳台']);
    const southwest = html.slice(html.indexOf('data-group="西南"'), html.indexOf('data-group="西北"'));
    for (const name of ['重庆市', '四川省', '贵州省', '云南省', '西藏']) assert.ok(southwest.includes(`data-name="${name}"`), name);
    assert.match(html, /^<!--include cbi\/valueheader-->/);
    assert.match(html, /<!--include cbi\/valuefooter-->\s*$/);
    assert.match(html, /id="cbid\.minigate\.global\.access_regions\.panel" hidden="hidden"/);
});

test('region selector accepts the old list format and falls back to the default region', { skip: !lua }, () => {
    const out = run(`
        local function checked(html) local n = 0; for _ in html:gmatch('checked="checked"') do n = n + 1 end; return n end
        print(checked(render_regions('510000 500000 440000')), checked(render_regions(nil)), render_regions(nil):match('value="510000" checked') ~= nil)
    `);
    assert.equal(out.trim(), '3\t1\ttrue');
});

test('region choices are saved as one string and a hidden field never blocks saving the page', { skip: !lua }, () => {
    const out = run(`
        local o = options.access_regions
        print(o.validate(o, {'510000', '500000'}, 'global'), o.validate(o, '510000', 'global'))
        print(o.validate(o, {'510000', '990000'}, 'global'), (select(2, o.validate(o, nil, 'global'))))
        local parsed = 0
        MultiValue = {parse=function() parsed = parsed + 1 end}
        local form = {}
        o.map = {formvalue=function(_, key) return form[key] end}
        o.parse(o, 'global')
        form['cbid.minigate.global.access_enabled'] = '1'
        o.parse(o, 'global')
        print(parsed)
    `);
    assert.equal(out.trim(), '510000 500000\t510000\nnil\t请选择至少一个允许的地区\n1');
});

test('region selector script keeps the page form intact and styles follow the theme', () => {
    const html = fs.readFileSync(template, 'utf8');
    const style = fs.readFileSync(path.join(root, 'luasrc/view/minigate/style.htm'), 'utf8');
    // 芯片的移除按钮、清空按钮都不能提交表单；搜索框回车不提交
    assert.match(html, /remove\.type='button'/);
    assert.match(html, /<button type="button" class="cbi-button mgx-region-clear">/);
    assert.match(html, /search\.onkeydown=function\(e\)\{if\(e\.key==='Enter'\)e\.preventDefault\(\);\}/);
    assert.match(style, /\.mgx-region-items\{display:grid;grid-template-columns:repeat\(auto-fill,minmax\(9\.5em,1fr\)\)/);
    assert.match(style, /\.mgx-region \[hidden\]\{display:none!important\}/);
});
