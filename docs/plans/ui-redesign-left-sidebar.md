# Plan: thiết kế lại UI/UX HiDisplay — sidebar bên trái + rà soát tính năng so với đối thủ

Ngày: 2026-10-15 · Phiên bản hiện tại: 0.7.1 · Trạng thái: **giai đoạn 0, 1 và 3 đã triển khai trên nhánh `claude/ui-ux-left-menu-0q82gw`; giai đoạn 2, 4, 5 còn lại**

Tài liệu này gồm ba phần:

1. Hiện trạng UI và các vấn đề UX tìm thấy khi đọc code.
2. Thiết kế mới: cửa sổ Settings dùng sidebar bên trái, menu bar panel và HiDPI làm lại theo từng giai đoạn.
3. Rà soát tính năng so với BetterDisplay, Lunar, MonitorControl, DisplayBuddy — thiếu gì, nên làm gì trước.

---

## 1. Hiện trạng

### 1.1 Cấu trúc UI hiện tại

| Thành phần | File | Hiện trạng |
| --- | --- | --- |
| Cửa sổ Settings | `Sources/HiDisplay/Settings/SettingsView.swift` | Segmented picker 5 mục ở trên (General / Displays / HiDPI / Keyboard / Diagnostics), 580 × 520 pt. Mỗi tab là một `VStack` tự do, không dùng `Form`. |
| Tab Displays | cùng file | `HSplitView`: list màn hình bên trái, chi tiết bên phải (resolution, refresh rate, controller, probe). |
| Tab HiDPI | `Sources/HiDisplay/HiDPI/HiDPISettingsTab.swift` | 9 section xếp dọc trong một `ScrollView`, picker màn hình riêng, nút Install ghim đáy. |
| Menu bar panel | `Sources/HiDisplay/MenuBar/MenuContent.swift` | `MenuBarExtra(.window)` rộng 300 pt: mỗi màn hình một section (tên, slider, nhãn controller, picker resolution), rồi Sync / Reset / Settings / Quit. |
| HUD độ sáng | `Sources/HiDisplay/BrightnessOSD.swift` | Đã làm theo kiểu macOS 27 (glass capsule, 16 vạch). Giữ nguyên. |
| Hộp thoại đổi resolution | `Sources/HiDisplay/ModeChangeCoordinator.swift` | `NSAlert` modal đếm ngược 15 s. Cố ý modal — giữ cơ chế, chỉ cân nhắc hình thức. |

Toàn bộ layer UI không có test; logic đáng test đều ở `HiDisplayKit` (đúng quy tắc trong `docs/architecture.md`). Plan này giữ nguyên quy tắc đó.

### 1.2 Vấn đề UX tìm thấy khi đọc code

Xếp theo mức ảnh hưởng. Mục nào có thể sửa độc lập với redesign thì ghi rõ.

| # | Vấn đề | Chứng cứ | Sửa độc lập được? |
| --- | --- | --- | --- |
| U1 | **`lastError` dùng chung cho mọi tab.** Lỗi export diagnostics hiện dưới mục Resolution và ngược lại. | `SettingsView.swift:178` và `:305` cùng đọc `model.lastError`; `AppModel.setMode` và `exportDiagnostics` cùng ghi. | Có — tách thành `modeError` / `diagnosticsError` hoặc struct `UserFacingError(scope:)`. |
| U2 | **Chọn màn hình không đồng bộ giữa các tab.** Displays tab và HiDPI tab mỗi nơi một `@State selection`. Chọn monitor ở Displays rồi sang HiDPI lại phải chọn lại. | `SettingsView.swift:57`, `HiDPISettingsTab.swift:14` | Có — đưa `selectedDisplayID` lên `AppModel`. |
| U3 | **Không có trạng thái "đang dò".** Khi `controller(for:)` còn `nil` (probe chưa xong, hoặc display đang *held* chờ DDC) menu hiện "No brightness control available" — người dùng hiểu là không hỗ trợ. | `MenuContent.swift:153` | Có — cần cờ `isProbing` / `isHeld` từ coordinator. |
| U4 | **Văn bản giải thích quá dài trong UI.** Nhiều đoạn 3–5 dòng `.caption` (HiDPI banner, Keyboard, General). Đọc như README, chiếm chỗ của control. | HiDPI tab: 6 đoạn caption; Keyboard: 3 đoạn. | Một phần — chuyển sang disclosure "Tìm hiểu thêm" / help popover. |
| U5 | **Lỗi hiển thị thô.** `"Could not plan the install: \(error)"`, `"Export failed: \(error)"` in nguyên mô tả Swift error. | `HiDPISettingsTab.swift:458, 558` | Có — `localizedDescription` + gợi ý hành động. |
| U6 | **Tiêu đề cửa sổ không đổi theo mục.** `Settings` scene luôn là "HiDisplay Settings"; segmented picker không có icon, không có trạng thái (ví dụ Accessibility chưa cấp). | `SettingsView.swift:25` | Đi cùng redesign. |
| U7 | **Menu panel cố định 300 pt**, tên monitor dài bị cắt (`lineLimit(1)`), không có tooltip. | `MenuContent.swift:59, 116` | Có. |
| U8 | **Không có empty state / onboarding.** Laptop không cắm monitor: menu chỉ có một dòng "Managed by macOS", không gợi ý gì. Lần chạy đầu không nói app làm gì, không nhắc quyền Accessibility hay Login item. | `MenuContent.swift:27-38` | Đi cùng redesign. |
| U9 | **HiDPI là màn hình nguy hiểm nhất nhưng ít dẫn dắt nhất.** 9 section phẳng, cảnh báo cam ở đầu, nút Install ở cuối — không có bước, không có tóm tắt "bạn sắp thêm N mode cho màn hình X". | `HiDPISettingsTab.swift:134-170` | Đi cùng redesign (wizard). |
| U10 | **Không có phím tắt / điều hướng bàn phím** trong Settings (ngoài ⌘, và ⌘Q). Không có VoiceOver label cho slider (slider không có `Label`). | `MenuContent.swift:137` | Một phần. |
| U11 | **Keyboard tab tên sai phạm vi**: chỉ là brightness keys, không phải cấu hình bàn phím. | `SettingsSection.keyboard` | Đi cùng redesign — đổi thành "Brightness Keys". |

---

## 2. Thiết kế mới

### 2.1 Nguyên tắc

- **Theo System Settings của macOS 15–27**: sidebar trái có icon màu, nội dung bên phải là `Form(.grouped)` chia section. Người dùng Mac đã quen bố cục này; app tiện ích không nên phát minh ngôn ngữ riêng.
- **macOS 15 là nền, macOS 26+ tự được Liquid Glass**: `NavigationSplitView` + `List(.sidebar)` recompile bằng Xcode 26 là có glass sidebar/toolbar, không cần code riêng. Mọi API chỉ có từ 26 phải gate `#available`, như HUD đang làm.
- **Không `TabView`**: lý do trong `SettingsView.swift:4-8` vẫn đúng (toolbar glass quá khổ).
- **Một màn hình = một trang.** Mọi thứ về *một* monitor (resolution, refresh, controller, probe, HiDPI của nó) đến từ một chỗ, với selection chung.
- **Lệnh cứu nguy luôn ở tầng đầu.** "Reset Dimming" giữ nguyên vị trí trong menu và thêm vào toolbar Settings.
- **Giữ ranh giới kiến trúc**: UI không gọi IOKit, không ghi file; logic mới (route, badge, trạng thái probe) nếu có nhánh thì đặt ở Kit để test được.

### 2.2 Cửa sổ Settings mới

```
┌──────────────────────────────────────────────────────────────────┐
│ ●●●   HiDisplay                                      [Reset Dim] │  ← toolbar glass (26+), title theo mục
├──────────────┬───────────────────────────────────────────────────┤
│ DISPLAYS     │  🖥  ViewSonic VX2780-2K          Main · DDC ●   │  ← header: tên, badge tier/controller
│  ● ViewSonic │                                                   │
│  ○ Built-in  │  ┌ Resolution ───────────────────────────────┐    │
│              │  │ Size            2560 × 1440 (HiDPI)   ▾   │    │  ← Form(.grouped), LabeledContent
│ TOOLS        │  │ Refresh rate    144 Hz                ▾   │    │
│  ◧ HiDPI     │  │ Show all resolutions              [  ]    │    │
│              │  └───────────────────────────────────────────┘    │
│ APP          │  ┌ Brightness ───────────────────────────────┐    │
│  ⚙ General   │  │ Controller   ◉ Automatic (DDC)            │    │
│  ⌨ Bright.   │  │              ○ DDC  ○ Gamma  ○ Shade      │    │
│    Keys      │  │ Probe        DDC ok · frame withHost…  ⓘ  │    │  ← chi tiết probe trong disclosure
│  🩺 Diagnost.│  └───────────────────────────────────────────┘    │
│              │  ┌ Identity ─────────────────────────────────┐    │
│              │  │ Profile key  v5a63-p003f-e9c1…    [copy]  │    │
│              │  │ Tier         Strong (EDID hash)      ⓘ    │    │
│              │  └───────────────────────────────────────────┘    │
│ v0.7.1       │                                                   │
└──────────────┴───────────────────────────────────────────────────┘
   sidebar 200–240 pt                   detail min 520 pt
```

**Sidebar (trái)** — ba nhóm:

| Nhóm | Mục | Icon SF | Ghi chú |
| --- | --- | --- | --- |
| Displays | Một hàng cho mỗi màn hình đang cắm | `display` / `laptopcomputer` | Hàng có badge: `Main`, controller (bolt = hardware, half-circle = software), cảnh báo cam nếu identity chưa xác nhận hoặc có warning. Danh sách này cập nhật theo `model.displays` (hot-plug). |
| Tools | HiDPI Overrides | `rectangle.expand.vertical` | Trang wizard, chọn màn hình đồng bộ với `selectedDisplayID`. |
| App | General · Brightness Keys · Diagnostics | `gearshape` · `keyboard` · `stethoscope` | Brightness Keys có badge cam khi Accessibility chưa cấp. |

Footer sidebar: version + nút "Check for updates" (xem mục 3, F12).

**Detail (phải)** — `Form` + `.formStyle(.grouped)`, mỗi `Section` có header ngắn; mọi đoạn giải thích dài hơn 2 dòng chuyển thành `DisclosureGroup("Tại sao…")` hoặc nút `ⓘ` mở popover. Nội dung giải thích giữ nguyên lời — chỉ đổi chỗ, vì chúng là phần giá trị của app.

**Trang màn hình (per-display):**

- Header: tên, loại (Built-in / External), badge `Main`, badge controller hiện tại, native resolution, số mode.
- Section *Resolution*: picker size + picker refresh rate (giữ logic `sizeBinding` / `modeBinding` hiện có, không đổi), toggle "Show all", ghi chú countdown rút gọn 1 dòng.
- Section *Brightness*: slider lớn (lặp lại của menu, để chỉnh khi đang ở Settings), radio controller, dòng "Currently using", disclosure "Probe results".
- Section *Identity*: profile key (copy), tier + giải thích, nút "This is a separate display" khi ambiguous (hiện chỉ có trong menu).
- Section *HiDPI* (rút gọn): "N override mode đã cài · Mở HiDPI Overrides →" — link sang trang Tools với display đã chọn.
- Built-in: chỉ header + ghi chú "Managed by macOS" (giữ `builtInNote`).

**Trang HiDPI Overrides — làm lại thành 3 bước có thanh tiến trình:**

1. **Chọn** — màn hình (đồng bộ selection), slider custom scaling, danh sách resolution với sharpness label, custom width. Cảnh báo cam thu thành một dòng + "Đọc trước khi cài" (disclosure).
2. **Xem trước** — tóm tắt: "Thêm 3 mode cho ViewSonic VX2780-2K · file sẽ ghi: /Library/Displays/…/DisplayProductID-3f · 242 mode hiện có được giữ nguyên" + preview plist trong disclosure + validation issues.
3. **Cài / Xuất** — hai nút như hiện tại, kết quả (recovery package, Show in Finder, lệnh undo) hiện tại chỗ.

Thanh hành động ghim đáy: `Back · Next / Install… · Export Only…`. Logic `planInstall` → alert → `performInstall` giữ nguyên; chỉ UI đổi.

**Trang General:** Launch at login (+ trạng thái), Appearance của menu panel (nếu làm F9), Reset All Dimming, About (version, license, link docs).

**Trang Brightness Keys:** đổi tên từ Keyboard. Toggle bật, picker target, bảng modifier, trạng thái Accessibility với nút mở System Settings. Thêm: "Show on-screen indicator" toggle (hiện HUD luôn bật, không tắt được).

**Trang Diagnostics:** nút Export + Show in Finder, bảng shim status, và **mới**: bảng tóm tắt từng màn hình (controller, frame shape, checksum tolerance, tier) — dữ liệu đã có trong `DiagnosticsBuilder`, chỉ là chưa hiện.

### 2.3 Menu bar panel mới

```
┌──────────────────────────────────┐
│ 🖥 ViewSonic VX2780-2K     Main  │
│ ☼ ───────────●────────── ☀  72% │   ← slider với icon hai đầu, % monospaced
│ ⚡ DDC · 2560×1440 ▾   ⌥ fine    │   ← một dòng: controller + resolution picker
├──────────────────────────────────┤
│ 💻 Built-in Display              │
│    Managed by macOS              │
├──────────────────────────────────┤
│ [⇄ Sync]  [↺ Reset Dimming]      │   ← hai nút ngang, Reset luôn hiện
├──────────────────────────────────┤
│ Settings…  ⌘,          Quit  ⌘Q │
└──────────────────────────────────┘
```

- Chiều rộng 320 pt, tên monitor `lineLimit(1)` + `.help(tên đầy đủ)`.
- Trạng thái dò: khi controller `nil` và display đang probe/held → `ProgressView` nhỏ + "Đang dò DDC…" thay vì "No brightness control available" (U3).
- Warning / identity unconfirmed giữ nguyên, nhưng gom thành một hàng cam có icon.
- Empty state (chỉ có built-in): một dòng "Cắm màn hình ngoài để chỉnh độ sáng và HiDPI" + link Settings.
- Slider có `Label` ẩn cho VoiceOver: "Độ sáng ViewSonic…, 72 phần trăm".

### 2.4 Chi tiết kỹ thuật

- **Route:** `enum SettingsRoute: Hashable { case display(String), hiDPI, general, brightnessKeys, diagnostics }` trong `Sources/HiDisplay/Settings/SettingsRoute.swift`. `AppModel` giữ `@Published var settingsRoute` và `selectedDisplayID`. Khi màn hình đang chọn bị rút, route về màn hình đầu còn lại (giống fallback hiện tại ở `HiDPISettingsTab.display`).
- **Shell:** `NavigationSplitView(columnVisibility: .constant(.all)) { SettingsSidebar() } detail: { SettingsDetail() }`, `.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)`, `.toolbar(removing: .sidebarToggle)`. `.navigationTitle` theo route. Cửa sổ `minWidth 760, minHeight 560`.
- **Form:** `.formStyle(.grouped)`; trên macOS 26 thêm `.scrollContentBackground(.hidden)` sau `#available` để glass hiện qua — kiểm tra trên 15 không bị nền trắng.
- **Tách file:** `Settings/Pages/DisplayPage.swift`, `GeneralPage.swift`, `BrightnessKeysPage.swift`, `DiagnosticsPage.swift`; `HiDPI/HiDPIWizard.swift` + `HiDPIWizardSteps/*.swift`. `SettingsView.swift` chỉ còn shell.
- **Components dùng chung:** `StatusBadge(kind:)`, `InfoPopover(text:)`, `SectionNote(text:)` trong `Settings/Components/`.
- **Logic xuống Kit (có test):** 
  - `DisplayStatusSummary` (từ `DisplayDevice` + `BrightnessCoordinator` state → badge, dòng trạng thái, `isProbing`, `isHeld`) — hiện `BrightnessCoordinator` không lộ "held"/"probing" ra ngoài; cần thêm `@Published var phase: [String: BrightnessPhase]` (`probing`, `held`, `ready(kind)`, `unavailable`).
  - `UserFacingError` với `scope` để sửa U1.
- **Deployment target giữ macOS 15.** Mọi API 26+ qua `#available`. CI đang chạy `macos-26` + Xcode 26 nên compile được; cần một lần chạy tay trên máy macOS 15 trước khi release.
- **Localization sẵn sàng:** chuyển string sang `String(localized:)` khi viết lại trang (không dịch ngay, nhưng đừng viết thêm string cứng).

### 2.5 Giai đoạn triển khai

| Giai đoạn | Việc | File chính | Tiêu chí hoàn thành |
| --- | --- | --- | --- |
| **0. Chuẩn bị** (nửa ngày) | Sửa U1 (tách error), U2 (`selectedDisplayID` lên AppModel), thêm `BrightnessPhase` vào coordinator + test. Không đổi giao diện. | `AppModel.swift`, `BrightnessCoordinator.swift`, tests | `swift test` xanh; lỗi hiện đúng tab. |
| **1. Shell sidebar** (1 ngày) | `SettingsRoute`, `NavigationSplitView`, sidebar 3 nhóm, chuyển General / Brightness Keys / Diagnostics sang `Form(.grouped)`. Displays và HiDPI tạm nhúng view cũ vào detail. | `Settings/SettingsView.swift`, `SettingsRoute.swift`, `Pages/*` | Mở ⌘, thấy sidebar; mọi chức năng cũ còn hoạt động; chạy được trên macOS 15 và 26. |
| **2. Trang màn hình** (1–1,5 ngày) | `DisplayPage` với header + 4 section; sidebar hàng display có badge; xoá `HSplitView` cũ; nút pin identity có trong Settings. | `Pages/DisplayPage.swift`, `Components/*` | Hot-plug cập nhật sidebar; chọn display ở sidebar rồi sang HiDPI vẫn giữ. |
| **3. HiDPI wizard** (1,5 ngày) | 3 bước, thanh hành động ghim đáy, tóm tắt trước khi Install, lỗi thân thiện (U5). | `HiDPI/HiDPIWizard.swift` | Luồng Install/Export cho kết quả y hệt (so plist sinh ra trước/sau bằng test có sẵn `OverrideTests`). Nút Install không bao giờ phải cuộn mới thấy. |
| **4. Menu panel** (1 ngày) | Layout mới 2.3, trạng thái dò, empty state, VoiceOver label, tooltip. | `MenuBar/MenuContent.swift` | Reset Dimming vẫn 1 click; slider mượt như cũ (binding ghi thẳng, không đổi). |
| **5. Hoàn thiện** (1 ngày) | Dark/light, Reduce Transparency, Increase Contrast, keyboard nav, chụp màn hình mới cho README, changelog. | README, `docs/project-changelog.md` | Checklist accessibility ở 2.6 đạt; README có ảnh mới. |

Tổng: khoảng 6–7 ngày làm việc. Mỗi giai đoạn là một PR riêng, có thể ship từng phần (giai đoạn 1 đã dùng được).

### 2.6 Checklist chất lượng trước khi gộp

- [ ] Chạy trên macOS 15 (không glass) và 26 (glass) — không có nền trắng, không có control lệch.
- [ ] Reduce Transparency / Increase Contrast bật: sidebar và badge vẫn đọc được.
- [ ] Tab/⇧Tab đi qua mọi control; slider chỉnh được bằng ←/→.
- [ ] VoiceOver đọc tên màn hình + % cho slider; badge có `accessibilityLabel`.
- [ ] Rút monitor khi đang ở trang của nó → chuyển trang, không crash, không trang trắng.
- [ ] Cửa sổ nhỏ nhất (760 × 560): không mục nào bị cắt; HiDPI Install luôn thấy.
- [ ] `swift test` xanh, số test không giảm.

---

## 3. Rà soát tính năng so với đối thủ

Đối thủ so sánh: **BetterDisplay** (waydabber, có bản Pro trả phí), **Lunar** (alin23, free + Pro), **MonitorControl** (open source, cùng maintainer với BetterDisplay), **DisplayBuddy** (trả phí, có Windows). Thông tin lấy từ README/website chính thức của từng app và trang so sánh của DisplayBuddy (nguồn có lợi ích, chỉ dùng cho tính năng của chính DisplayBuddy).

### 3.1 Bảng so sánh

✅ có · ◐ một phần · ❌ không · — cố ý không làm (lý do trong docs)

| Tính năng | HiDisplay | BetterDisplay | Lunar | MonitorControl | DisplayBuddy |
| --- | --- | --- | --- | --- | --- |
| Độ sáng ngoài qua DDC (Apple Silicon) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fallback gamma / shade | ✅ | ✅ | ✅ | ✅ | ◐ |
| Phím F1/F2 cho màn ngoài + HUD | ✅ | ✅ | ✅ | ✅ | ✅ |
| Nhớ độ sáng theo monitor, re-assert khi wake | ✅ (điểm mạnh) | ✅ | ✅ | ◐ | ◐ |
| Định danh ổn định khi serial = 0, pin thủ công | ✅ (điểm mạnh) | ◐ | ◐ | ❌ | ❌ |
| HiDPI override + recovery package + verify hash | ✅ (điểm mạnh) | ◐ (cách khác: virtual display) | ❌ | ❌ | ❌ |
| Đổi resolution / refresh với countdown | ✅ | ✅ | ❌ | ❌ | ✅ |
| **Contrast (DDC 0x12)** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Volume / mute (DDC 0x62, 0x8D)** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Đổi input source (DDC 0x60)** | ❌ | ✅ | ✅ | ❌ | ✅ |
| **Sync độ sáng theo màn built-in (ambient)** | ❌ | ✅ | ✅ (3 chế độ) | ◐ | ❌ |
| Lịch / theo mặt trời | ❌ | ✅ | ✅ | ❌ | ✅ |
| **Dim dưới 0% (DDC + gamma kết hợp)** | ❌ | ✅ | ✅ | ❌ | ❌ |
| **Preset / scene nhiều màn hình** | ❌ | ✅ | ✅ | ❌ | ✅ (điểm mạnh) |
| **Shortcuts app / CLI / URL scheme** | ◐ (`hidisplay-probe` chỉ chẩn đoán) | ✅ | ✅ | ❌ | ✅ |
| Phím tắt tuỳ chỉnh toàn cục | ❌ | ✅ | ✅ | ◐ | ✅ |
| Widget / Siri | ❌ | ❌ | ❌ | ❌ | ✅ |
| Bật/tắt nguồn, sleep màn hình (DDC 0xD6) | ❌ | ✅ | ✅ | ❌ | ✅ |
| Xoay màn hình | ❌ | ✅ | ❌ | ❌ | ✅ |
| HDR toggle | ❌ (`supportsHDR` có nhưng chưa dùng) | ✅ | ❌ | ❌ | ❌ |
| Virtual / dummy display, PiP, mirror | — | ✅ | ❌ | ❌ | ❌ |
| Scale "live" không logout | — (cần private CG API) | ✅ | ❌ | ❌ | ❌ |
| Intel Mac | — | ✅ | ✅ | ✅ | ✅ |
| **Notarized / Developer ID** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Tự cập nhật trong app** | ❌ | ✅ | ✅ | ✅ | ✅ |
| Đa ngôn ngữ | ❌ | ✅ | ◐ | ✅ | ◐ |
| Onboarding lần đầu | ❌ | ✅ | ✅ | ◐ | ✅ |
| Nhẹ, không daemon, không dependency, mã mở | ✅ (điểm mạnh) | ◐ | ◐ | ✅ | ❌ |

### 3.2 Khoảng trống nên lấp, xếp theo ưu tiên

Tiêu chí: giá trị với người dùng màn ngoài trên Apple Silicon × chi phí × rủi ro với triết lý "không làm hỏng monitor" của app.

| Ưu tiên | Mã | Tính năng | Vì sao | Chi phí | Rủi ro / ghi chú kỹ thuật |
| --- | --- | --- | --- | --- | --- |
| **P0** | F1 | **Notarize + Developer ID** | Mọi đối thủ đều có. Hiện người dùng phải `xattr -dr`; đây là rào cản lớn nhất, không phải tính năng. | Thấp (tiền + script) | `package-release.sh` đã có chỗ; cần `notarytool`. Cũng mở đường cho SMAppService helper đã ghi trong README. |
| **P0** | F2 | **Kiểm tra cập nhật** | Không có cách nào người dùng biết có bản mới. | Thấp | Không dùng Sparkle (chính sách no-dependency): gọi GitHub Releases API, so version, mở link tải. Nút ở footer sidebar. |
| **P1** | F3 | **Contrast qua DDC** | Có ở cả 4 đối thủ; không thể làm hỏng monitor (chỉ là giá trị 0–100). | Thấp | Thêm `VCPCode.contrast = 0x12`; probe riêng, fallback là ẩn slider. Mở rộng `VCPCode` đồng nghĩa phải xoá câu "deliberately absent" ở `VCP.swift:3` và viết lại lý do: cho phép từng code sau khi có cơ chế an toàn. |
| **P1** | F4 | **Sync độ sáng với màn built-in** (chế độ "theo laptop") | Tính năng Lunar được yêu thích nhất; HiDisplay đã có `DisplayServicesShim` đọc được built-in. Chỉ *đọc* built-in, vẫn không ghi — giữ đúng ranh giới. | Trung bình | Poll `DisplayServicesGetBrightness` ~1 s hoặc theo notification nếu còn; curve ánh xạ có thể chỉnh (min/max) vì 50% laptop ≠ 50% monitor. Tắt khi người dùng kéo slider thủ công (một lần chạm thì tạm ngưng N phút). |
| **P1** | F5 | **Shortcuts (App Intents)** | Rẻ, mở đường tự động hoá (dock vào → set 70%). Không cần CLI riêng. | Thấp–trung bình | `AppIntent` cho `SetBrightness(display, value)`, `ResetDimming`, `ApplyPreset`. Target hiện là SwiftPM executable; cần kiểm tra App Intents với `build-app.sh` (metadata extraction). |
| **P1** | F6 | **Dim dưới 0%** | `BrightnessState` đã có `hardwareValue` + `softwareValue` — thiết kế đã chuẩn bị. Người dùng OLED/đêm cần. | Trung bình | Slider 0–100 giữ nguyên; thêm vùng "sub-zero" (ví dụ −30…0) chỉ khi DDC ở 0, dùng gamma. Reset Dimming phải xoá cả phần này. |
| **P2** | F7 | **Preset / scene** | DisplayBuddy xây cả sản phẩm quanh đây. HiDisplay có profile store sẵn. | Trung bình | `Preset { name, perDisplay: [key: (brightness, mode?)] }` trong `ProfileDocument` (schema 3). Áp dụng từ menu và Shortcuts. |
| **P2** | F8 | **Volume / mute** | Có ở mọi đối thủ. | Thấp | Rủi ro "mute nhầm" như comment trong `VCP.swift`: chỉ bật sau probe xác nhận 0x62 trả lời, và không auto-restore volume khi wake (khác brightness). |
| **P2** | F9 | **Input source** | Nhu cầu KVM-lite rất thật (một monitor, Mac + PC). | Trung bình | Rủi ro thật: chuyển sang input chết thì không có đường quay lại qua DDC. Giảm thiểu: chỉ liệt kê input đã từng thấy (đọc 0x60 capabilities string), xác nhận trước khi gửi, ghi vào docs/recovery. |
| **P2** | F10 | **Phím tắt toàn cục tuỳ chỉnh** | Người không có F1/F2 (bàn phím rời). | Trung bình | Tận dụng `BrightnessKeyTap` đang có; thêm recorder đơn giản. |
| **P3** | F11 | **Lịch / theo mặt trời** | Phụ thuộc F4 xong; Location cần quyền. | Trung bình | Có thể làm bản "lịch cố định" trước, không cần Location. |
| **P3** | F12 | **Localization (vi, en)** | Người làm app là người Việt; chi phí thấp khi redesign đã dùng `String(localized:)`. | Thấp | `Localizable.xcstrings` trong `Resources`. |
| **P3** | F13 | Power/sleep màn hình (0xD6), HDR toggle, xoay | Có nhu cầu nhưng nhỏ; xoay dùng được API công khai. | Thấp mỗi mục | Làm sau khi F3/F8 chứng minh mô hình "mở từng VCP code" ổn. |
| — | — | Virtual display, live scaling, Intel | Cố ý không làm; đã ghi trong README/docs. Giữ nguyên quyết định. | — | — |

### 3.3 Những thứ HiDisplay đang làm tốt hơn đối thủ — đừng đánh mất khi redesign

- **An toàn cài override**: kế hoạch hiển thị trước khi hỏi mật khẩu, recovery package tạo *trước* khi ghi, hash-verify sau. Wizard mới phải giữ nguyên ba thứ này ở bước 2–3.
- **Không flash khi wake / boot** (hold cho DDC). UI mới phải *hiện* trạng thái held thay vì giấu (U3) — đây là chỗ biến điểm mạnh kỹ thuật thành điểm mạnh nhìn thấy được.
- **Giải thích tier định danh** và nút pin. Đưa vào trang màn hình, đừng chỉ để trong menu.
- **Không daemon, không dependency, không tắt SIP.** F2 và F5 phải làm bằng API hệ thống, không thêm package.

---

## 4. Thứ tự đề xuất

1. Giai đoạn 0–1 của redesign (sửa U1/U2/U3 + shell sidebar) — ship được ngay, rủi ro thấp.
2. F1 notarize + F2 update check — không liên quan UI, có thể làm song song.
3. Giai đoạn 2–4 (trang màn hình, wizard, menu).
4. F3 contrast + F4 sync built-in — hai tính năng đầu tiên lấp khoảng trống với đối thủ, và trang màn hình mới đã có chỗ sẵn cho chúng.
5. F5–F7, rồi phần còn lại theo bảng.

## Nguồn tham khảo cho phần 3

- BetterDisplay: https://github.com/waydabber/betterdisplay · https://betterdisplay.pro/
- Lunar: https://github.com/alin23/Lunar
- MonitorControl: https://github.com/MonitorControl/MonitorControl
- DisplayBuddy: https://displaybuddy.app/docs/presets · https://displaybuddy.app/docs/automation-cli · https://www.displaybuddy.app/displaybuddy-vs-betterdisplay (nguồn có lợi ích)
