-- luacheck: globals describe it assert

local Mokuro = require("MangaOCRMokuro")

describe("Mokuro schema helpers", function()
    it("preserves page ordinals around partial null pages", function()
        local data = assert(Mokuro.decode([[
            {
                "version": "0.2",
                "pages": [
                    {
                        "img_width": 100,
                        "img_height": 200,
                        "blocks": [{"box":[1,2,30,40],"lines":["one"]}]
                    },
                    null,
                    {
                        "img_width": 300,
                        "img_height": 400,
                        "blocks": [{"box":[3,4,50,60],"lines":["three"]}]
                    }
                ]
            }
        ]]))

        assert.are.equal(3, data.page_count)
        assert.are.equal(2, data.valid_page_count)
        assert.is_nil(Mokuro.getPage(data, 2))
        assert.are.equal(3, Mokuro.getPage(data, 3).ordinal)
        assert.are.equal("three", Mokuro.getBlockText(Mokuro.getPage(data, 3).blocks[1]))
    end)

    it("skips malformed blocks without rejecting a usable page", function()
        local data = assert(Mokuro.decode([[
            {
                "pages": [{
                    "img_width": 100,
                    "img_height": 100,
                    "blocks": [
                        {"box":[0,0,"bad",10],"lines":["bad"]},
                        {"box":[20,30,40,70],"lines":["good"]}
                    ]
                }]
            }
        ]]))

        assert.are.equal(1, #Mokuro.getPage(data, 1).blocks)
        assert.are.equal("good", Mokuro.getBlockText(Mokuro.getPage(data, 1).blocks[1]))
    end)

    it("joins Japanese lines without inserting spaces", function()
        assert.are.equal(
            "今日はいい天気。",
            Mokuro.getBlockText({ lines = { "今日は", "いい天気。" } })
        )
        assert.are.equal(
            "第1話",
            Mokuro.getBlockText({ lines = { "第", "1話" } })
        )
    end)

    it("keeps Latin word boundaries and punctuation", function()
        assert.are.equal(
            "hello world",
            Mokuro.getBlockText({ lines = { "hello", "world" } })
        )
        assert.are.equal(
            "Hello, world!",
            Mokuro.getBlockText({ lines = { "Hello,", "world!" } })
        )
        assert.are.equal(
            "already spaced",
            Mokuro.getBlockText({ lines = { "already ", "spaced" } })
        )
    end)

    it("hides only small kana positioned as furigana beside kanji", function()
        local raw = assert(Mokuro.decode([=[
            {
                "pages": [{
                    "img_width": 600,
                    "img_height": 800,
                    "blocks": [
                        {
                            "box": [500,50,530,250],
                            "vertical": true,
                            "lines": ["かなのみ"],
                            "lines_coords": [
                                [[500,50],[530,50],[530,250],[500,250]]
                            ]
                        },
                        {
                            "box": [310,100,390,280],
                            "vertical": true,
                            "lines": ["よみ","漢字列一","漢字列二"],
                            "lines_coords": [
                                [[380,120],[390,120],[390,200],[380,200]],
                                [[350,100],[380,100],[380,260],[350,260]],
                                [[310,100],[340,100],[340,280],[310,280]]
                            ]
                        },
                        {
                            "box": [200,350,210,420],
                            "vertical": true,
                            "lines": ["かな"],
                            "lines_coords": [
                                [[200,350],[210,350],[210,420],[200,420]]
                            ]
                        },
                        {
                            "box": [170,350,200,600],
                            "vertical": true,
                            "lines": ["漢字列三"],
                            "lines_coords": [
                                [[170,350],[200,350],[200,600],[170,600]]
                            ]
                        },
                        {
                            "box": [100,50,150,200],
                            "vertical": true,
                            "lines": ["カナ"],
                            "lines_coords": [
                                [[100,50],[150,50],[150,200],[100,200]]
                            ]
                        }
                    ]
                }]
            }
        ]=]))

        local filtered = Mokuro.withoutFurigana(raw)
        local page = Mokuro.getPage(filtered, 1)

        assert.are.equal(4, #page.blocks)
        assert.are.equal("かなのみ", Mokuro.getBlockText(page.blocks[1]))
        assert.are.same({ "漢字列一", "漢字列二" }, page.blocks[2].lines)
        assert.are.same({ 310, 100, 380, 280 }, page.blocks[2].box)
        assert.are.equal("漢字列三", Mokuro.getBlockText(page.blocks[3]))
        assert.are.equal("カナ", Mokuro.getBlockText(page.blocks[4]))

        -- Filtering is display-only and can be reversed without OCR.
        assert.are.same(
            { "よみ", "漢字列一", "漢字列二" },
            Mokuro.getPage(raw, 1).blocks[2].lines
        )
        assert.are.equal(5, #Mokuro.getPage(raw, 1).blocks)
    end)

    it("recognizes katakana ruby by geometry but keeps uncertain kana", function()
        local raw = assert(Mokuro.decode([=[
            {
                "pages": [{
                    "img_width": 500,
                    "img_height": 500,
                    "blocks": [
                        {
                            "box": [100,100,140,300],
                            "vertical": true,
                            "lines": ["漢字"],
                            "lines_coords": [
                                [[100,100],[140,100],[140,300],[100,300]]
                            ]
                        },
                        {
                            "box": [142,120,160,280],
                            "vertical": true,
                            "lines": ["カンジ"],
                            "lines_coords": [
                                [[142,120],[160,120],[160,280],[142,280]]
                            ]
                        },
                        {
                            "box": [200,100,235,300],
                            "vertical": true,
                            "lines": ["かなだけ"],
                            "lines_coords": [
                                [[200,100],[235,100],[235,300],[200,300]]
                            ]
                        },
                        {
                            "box": [142,320,160,390],
                            "vertical": true,
                            "lines": ["とおい"],
                            "lines_coords": [
                                [[142,320],[160,320],[160,390],[142,390]]
                            ]
                        },
                        {
                            "box": [145,100,158,180],
                            "vertical": true,
                            "lines": ["座"],
                            "lines_coords": []
                        }
                    ]
                }]
            }
        ]=]))

        local page = Mokuro.getPage(Mokuro.withoutFurigana(raw), 1)
        assert.are.equal(4, #page.blocks)
        assert.are.equal("漢字", Mokuro.getBlockText(page.blocks[1]))
        assert.are.equal("かなだけ", Mokuro.getBlockText(page.blocks[2]))
        assert.are.equal("とおい", Mokuro.getBlockText(page.blocks[3]))
        assert.are.equal("座", Mokuro.getBlockText(page.blocks[4]))
    end)

    it("removes selection spaces only between actual CJK characters", function()
        assert.are.equal("日本", Mokuro.cleanupSelection("  日本"))
        assert.are.equal("日本", Mokuro.cleanupSelection("日 本"))
        assert.are.equal("日本", Mokuro.cleanupSelection("日\n本"))
        assert.are.equal("ấ ộ", Mokuro.cleanupSelection("ấ ộ"))
    end)

    it("maps image coordinates only into native page space", function()
        local rect = assert(Mokuro.boxToNativeRect(
            { 10, 20, 60, 120 },
            100,
            200,
            { w = 600, h = 800 }
        ))

        assert.are.equal(60, rect.x)
        assert.are.equal(80, rect.y)
        assert.are.equal(300, rect.w)
        assert.are.equal(400, rect.h)
    end)
end)
