--- Tests for ai-chat.proposals.parse — Response parsing
local parse = require("ai-chat.proposals.parse")

describe("proposals.parse", function()
    describe("_parse_fence_info", function()
        it("parses file=path lines=N-M", function()
            local file, ls, le = parse._parse_fence_info("lua file=src/config.lua lines=42-50")
            assert.equals("src/config.lua", file)
            assert.equals(42, ls)
            assert.equals(50, le)
        end)

        it("parses file=path without lines", function()
            local file, ls, le = parse._parse_fence_info("lua file=src/config.lua")
            assert.equals("src/config.lua", file)
            assert.is_nil(ls)
            assert.is_nil(le)
        end)

        it("parses file=path with double quotes", function()
            local file, _, _ = parse._parse_fence_info('lua file="src/config.lua"')
            assert.equals("src/config.lua", file)
        end)

        it("parses file=path with single quotes", function()
            local file, _, _ = parse._parse_fence_info("lua file='src/config.lua'")
            assert.equals("src/config.lua", file)
        end)

        it("parses file: path (colon variant)", function()
            local file, _, _ = parse._parse_fence_info("lua file: src/config.lua")
            assert.equals("src/config.lua", file)
        end)

        it("parses File: path (capitalized colon variant)", function()
            local file, _, _ = parse._parse_fence_info("lua File: src/config.lua")
            assert.equals("src/config.lua", file)
        end)

        it("strips trailing comma from path", function()
            local file, _, _ = parse._parse_fence_info("lua file=src/config.lua,")
            assert.equals("src/config.lua", file)
        end)

        it("parses path after language (fallback)", function()
            local file, ls, le = parse._parse_fence_info("lua src/config.lua")
            assert.equals("src/config.lua", file)
            assert.is_nil(ls)
            assert.is_nil(le)
        end)

        it("parses path with file extension but no slash", function()
            local file, _, _ = parse._parse_fence_info("lua config.lua")
            assert.equals("config.lua", file)
        end)

        it("returns nil for language-only fence", function()
            local file, _, _ = parse._parse_fence_info("lua")
            assert.is_nil(file)
        end)

        it("returns nil for empty fence info", function()
            local file, _, _ = parse._parse_fence_info("")
            assert.is_nil(file)
        end)

        it("ignores flags that look like options", function()
            local file, _, _ = parse._parse_fence_info("lua --strict")
            assert.is_nil(file)
        end)
    end)

    describe("_extract_code_blocks", function()
        it("extracts a single code block", function()
            local text = "Some text\n```lua file=test.lua\nlocal x = 1\n```\nMore text"
            local blocks = parse._extract_code_blocks(text)
            assert.equals(1, #blocks)
            assert.equals("lua file=test.lua", blocks[1].fence_info)
            assert.equals("local x = 1", blocks[1].content)
        end)

        it("extracts multiple code blocks", function()
            local text = "Block 1:\n```lua file=a.lua\nA\n```\nBlock 2:\n```lua file=b.lua\nB\n```"
            local blocks = parse._extract_code_blocks(text)
            assert.equals(2, #blocks)
            assert.equals("A", blocks[1].content)
            assert.equals("B", blocks[2].content)
        end)

        it("captures multi-line content", function()
            local text = "```lua file=test.lua\nline1\nline2\nline3\n```"
            local blocks = parse._extract_code_blocks(text)
            assert.equals(1, #blocks)
            assert.equals("line1\nline2\nline3", blocks[1].content)
        end)

        it("captures preceding text", function()
            local text = "Fix the nil guard:\n```lua file=test.lua\ncode\n```"
            local blocks = parse._extract_code_blocks(text)
            assert.equals(1, #blocks)
            assert.truthy(blocks[1].preceding_text:match("nil guard"))
        end)

        it("handles blocks with no file annotation", function()
            local text = "Example:\n```lua\nlocal x = 1\n```"
            local blocks = parse._extract_code_blocks(text)
            assert.equals(1, #blocks)
            assert.equals("lua", blocks[1].fence_info)
        end)

        it("returns empty for text with no code blocks", function()
            local blocks = parse._extract_code_blocks("No code here, just text.")
            assert.equals(0, #blocks)
        end)
    end)

    describe("_extract_description", function()
        it("extracts last non-empty line", function()
            local desc = parse._extract_description("Some context\n\nAdd nil guard for opts parameter")
            assert.equals("Add nil guard for opts parameter", desc)
        end)

        it("strips markdown bold", function()
            local desc = parse._extract_description("**Add nil guard**")
            assert.equals("Add nil guard", desc)
        end)

        it("strips markdown headers", function()
            local desc = parse._extract_description("### Add nil guard")
            assert.equals("Add nil guard", desc)
        end)

        it("strips numbered list prefix", function()
            local desc = parse._extract_description("1. Add nil guard")
            assert.equals("Add nil guard", desc)
        end)

        it("strips trailing colon", function()
            local desc = parse._extract_description("Add nil guard:")
            assert.equals("Add nil guard", desc)
        end)

        it("truncates long descriptions", function()
            local long = string.rep("x", 100)
            local desc = parse._extract_description(long)
            assert(#desc <= 80, "description should be truncated to 80 chars")
        end)

        it("returns default for empty text", function()
            local desc = parse._extract_description("")
            assert.equals("AI-proposed change", desc)
        end)
    end)

    describe("_resolve_path", function()
        it("returns nil for nonexistent file", function()
            assert.is_nil(parse._resolve_path("/tmp/definitely_nonexistent_abc123.lua"))
        end)

        it("resolves absolute paths that exist", function()
            -- Create a temp file to test against
            local tmp = os.tmpname()
            local f = io.open(tmp, "w")
            f:write("test")
            f:close()
            local result = parse._resolve_path(tmp)
            assert.equals(tmp, result)
            os.remove(tmp)
        end)
    end)

    describe("parse (integration)", function()
        it("returns empty proposals for text without code blocks", function()
            local result = parse.parse("No code here", "conv-1")
            assert.equals(0, #result.proposals)
            assert.equals(0, #result.warnings)
        end)

        it("skips unannotated code blocks", function()
            local text = "Example:\n```lua\nlocal x = 1\n```"
            local result = parse.parse(text, "conv-1")
            assert.equals(0, #result.proposals)
            assert.equals(0, #result.warnings)
        end)

        it("produces warning for nonexistent file", function()
            local text = "Fix:\n```lua file=/tmp/nonexistent_abc123.lua\ncode\n```"
            local result = parse.parse(text, "conv-1")
            assert.equals(0, #result.proposals)
            assert.equals(1, #result.warnings)
            assert.truthy(result.warnings[1]:match("not found"))
        end)
    end)
end)
