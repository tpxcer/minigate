const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { root, geoDir } = require('./helpers/access-fixture.cjs');
const path = require('node:path');

const lua = process.env.MINIGATE_TEST_LUA;

test('LuCI access settings offer all provinces, default off, validate multiple choices and reject invalid values', { skip: !lua }, () => {
    const result = spawnSync(lua, ['-'], { encoding: 'utf8', input: `
        local options = {}
        package.preload['luci.sys'] = function() return {} end
        package.preload['luci.model.uci'] = function()
            return {cursor=function() return {foreach=function() end, get=function() end} end}
        end
        Flag, Value, DynamicList, ListValue, DummyValue = 'Flag', 'Value', 'DynamicList', 'ListValue', 'DummyValue'
        NamedSection, TypedSection = 'NamedSection', 'TypedSection'
        function Map()
            return {section=function()
                return {option=function(self, kind, name)
                    local option = {kind=kind, choices={}}
                    function option:value(key, label) self.choices[key] = label end
                    function option:depends(key, value) self.dependency={key,value} end
                    options[name] = option
                    return option
                end}
            end}
        end
        local real_open = io.open
        io.open = function(file, mode)
            if file == '/usr/lib/minigate/geo/regions.txt' then file = ${JSON.stringify(path.join(geoDir, 'regions.txt'))} end
            return real_open(file, mode)
        end
        assert(dofile(${JSON.stringify(path.join(root, 'luasrc/model/cbi/minigate/proxy.lua'))}))
        assert(options.access_enabled.default == '0')
        local regions = options.access_regions
        assert(regions.kind == 'DynamicList')
        assert(regions.default == '510000')
        assert(regions.dependency[1] == 'access_enabled' and regions.dependency[2] == '1')
        assert(regions.choices['510000'] == '四川省')
        local count = 0; for _ in pairs(regions.choices) do count = count + 1 end
        assert(count == 34)
        assert(regions:validate({'510000', '500000'}, 'global'))
        assert(regions:validate('510000', 'global'))
        assert(not regions:validate({}, 'global'))
        assert(not regions:validate({''}, 'global'))
        assert(not regions:validate({'990000'}, 'global'))
        assert(not regions:validate({'510000', '../500000'}, 'global'))
        print('LuCI access validation passed')
    ` });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /validation passed/);
});
