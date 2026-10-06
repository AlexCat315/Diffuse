# Browser demo fonts

These unmodified upstream fonts were retrieved on 2026-10-06 and are checked
into the repository so local/offline builds do not depend on a font CDN.
`manifest.json` records exact SHA-256 checksums and sizes. Browser loading order:

| File | Upstream source | License |
| --- | --- | --- |
| NotoSans.ttf | [google/fonts, ofl/notosans](https://github.com/google/fonts/tree/main/ofl/notosans) `NotoSans[wdth,wght].ttf` | OFL.txt |
| NotoSansCJKsc.otf | [noto-cjk, Sans/OTF/SimplifiedChinese](https://github.com/notofonts/noto-cjk/tree/main/Sans/OTF/SimplifiedChinese) `NotoSansCJKsc-Regular.otf` | OFL-CJK.txt |
| NotoSansArabic.ttf | [google/fonts, ofl/notosansarabic](https://github.com/google/fonts/tree/main/ofl/notosansarabic) `NotoSansArabic[wdth,wght].ttf` | OFL-Arabic.txt |
| NotoSansDevanagari.ttf | [google/fonts, ofl/notosansdevanagari](https://github.com/google/fonts/tree/main/ofl/notosansdevanagari) `NotoSansDevanagari[wdth,wght].ttf` | OFL-Devanagari.txt |
| NotoEmoji.ttf | [google/fonts, ofl/notoemoji](https://github.com/google/fonts/tree/main/ofl/notoemoji) `NotoEmoji[wght].ttf` | OFL-Emoji.txt |

NotoSans includes some Devanagari coverage, so a grapheme already covered by it
uses that face before the dedicated fallback. CJK coverage is the full Simplified
Chinese font; fonts total roughly 21 MiB. NotoEmoji renders monochrome outlines.
All files are redistributable under SIL Open Font License 1.1; preserve each
font's accompanying copyright/license when distributing the browser build.
