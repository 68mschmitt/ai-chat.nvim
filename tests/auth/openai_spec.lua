describe("openai auth", function()
    local store = require("ai-chat.auth.store")
    local auth = require("ai-chat.auth.openai")
    local tmpdir
    local original_system

    before_each(function()
        original_system = vim.system
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
        store._set_path(tmpdir .. "/auth.json")
    end)

    after_each(function()
        vim.system = original_system
        store._set_path(nil)
        vim.fn.delete(tmpdir, "rf")
    end)

    it("allows ensure when account id is missing", function()
        store.set("openai", {
            type = "oauth",
            refresh = "refresh-token",
            access = "access-token",
            expires = os.time() * 1000 + 3600000,
        })

        vim.system = function(_cmd, _opts, on_exit)
            vim.schedule(function()
                on_exit({ code = 0, stdout = "{}" })
            end)
            return { kill = function() end }
        end

        local ok_result, auth_result
        auth.ensure(function(ok, result)
            ok_result = ok
            auth_result = result
        end)
        vim.wait(1000, function()
            return ok_result ~= nil
        end)

        assert.is_true(ok_result)
        assert.is_table(auth_result)
        assert.is_nil(auth_result.accountId)
    end)
end)
