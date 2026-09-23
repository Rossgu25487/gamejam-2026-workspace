# 美术参考与提示词

这份资料供两位美术及其 agent 开始样例任务时读取。当前默认校准低饱和纸片插画，硬边套色作为降低制作精度的备选。尚无已认可的运行资源。

- [方向对照图](../proposals/figures/美术方向对照.png)：仅供比较画法；PNG平面图，无分层源稿。
- [制作要求与角色任务](../proposals/04_策划结构配置与美术准备.md)：物件状态、画布、交接与检查方式。
- 参考尺寸1152×720；中景物件清晰，前景避开点击区，远景降低细节；文本独立绘制。
- 同一物件各状态共用位置、光向、画布和轮廓。保留可编辑源稿及必要透明PNG。
- 样例完成后只登记实际被认可的用途：样例ID、路径、作者/工具、提示词版本、输入参考来源、人工修改、认可范围与待改之处。未认可样例留本人工作目录，不标成正式资源。

## 现有样例

ART-DIRECTION-01，2026-09-24，内置 image_gen。用于同构图风格比较，尚未定稿。模型具体版本与seed未提供。图像SHA-256：40ec55b150932506d652d024ce0604a44f6f63c50bca3976292159b8da44937d。左列纹理需简化；右列像素网格未逐项校准；附加植物和箱子可删。没有外部图片作为本次输入。

## 实际生成提示词 v1

再次使用时记录改动，不把本次平面输出当作已有图层或透明资产。

```text
Use case: stylized-concept
Asset type: a single landscape art-direction comparison board for an original small 2D game, pre-theme research only.
Primary request: Create ONE wide triptych image, exactly THREE equally sized adjacent panels separated by slim plain neutral gutters. No headings, no captions, no lettering anywhere. Each panel depicts the SAME neutral repair-shop work counter using an IDENTICAL fixed camera, geometry, object arrangement and muted palette. This is a controlled comparison of three drawing methods suitable for a tiny team, with deliberately economical detail, not a polished AAA concept painting.
Shared scene in ALL THREE panels: straight-on slightly elevated view of a wooden counter occupying the lower middle, a dark simple doorframe along the left foreground edge, a softly simplified green-grey rear wall with a window in the upper middle and a small shelf to the right. On the counter are exactly THREE main repair objects, from left to right: one old desk lamp with a downward-facing metal shade, one round clock standing on a small base, and one rectangular tabletop radio with a circular tuning knob and a simple speaker grille. The clock face has tick marks but NO numerals. The radio has NO labels or letters. Repeat their silhouettes, scale, arrangement, and spacing faithfully across all panels. Do not add tools, bottles, books, papers, extra clocks or any other tabletop props.
Depth: dark near doorframe as a broad foreground silhouette; clean readable shapes and edges on the counter and the three objects in the middle plane; reduced contrast and softer detail on the distant wall, window and shelf. Preserve breathing room around the objects. Pixel panel achieves distant softness through simplified low-contrast large shapes rather than smearing pixels. The tabletop remains easy to read.
Lighting and palette: warm soft light from the UPPER LEFT in every panel; gentle warm highlights on old wood and metal; cool desaturated grey-green surroundings; dark charcoal foreground; off-white small highlights; a humane, quietly cared-for atmosphere around old everyday objects. Moderate contrast, legible midtones, no black crush.
Left panel: economical hand-painted PAPER-CUT ILLUSTRATION, matte gouache-like flat paper shapes with a little subtle texture, soft simplified material indication, understated imperfect contours. Clearly flat 2D illustration, limited layers and few values.
Middle panel: economical HARD-EDGED SPOT-COLOR PRINT / SCREENPRINT illustration, the same scene broken into a small number of flat color masses, restrained coarse print texture, firm graphic silhouettes, no tiny engraved detail.
Right panel: economical LIMITED-PALETTE CHUNKY PIXEL ART, consistent visible square pixel grid, simple bold pixel clusters, sharply stepped silhouettes, minimal dithering; the same three objects should each be readable at small size. No smooth painted edges in this panel.
Composition constraints: Same eye level, same crop and same layout across all three panels. Each panel is a complete small scene; do not blend scenes across panel boundaries. Prefer a 3:1 overall landscape composition. Keep the room intimate and the scene modest enough to recreate with two 2D artists working within 24 hours each.
Avoid: people, faces, characters, UI, HUD, labels, logos, watermark, text, dramatic cinematic lens effects, photorealism, 3D-rendered realism, elaborate microdetail, neon, cyberpunk, horror, blood, recognizable existing game IP, imitation of a specific game's scene.
```
