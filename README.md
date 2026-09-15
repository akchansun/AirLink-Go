# 互传 / AirLink Go

[中文](#中文) · [English](#english)

局域网文件互传：电脑 ↔ 电脑加密传输，手机扫码收发，无需注册、文件不走公网。

**产品名：** 互传  
**英文名：** AirLink Go  
**仓库：** [GitHub](https://github.com/akchansun/AirLink-Go) · [Gitee](https://gitee.com/akcg/AirLink-Go)  
**官网：** <https://www.ak129.cn/huchuan/>  
**开发者：** [喜相逢科技](https://www.ak129.cn/)

---

## 中文

### 这是什么
互传是一款免费开源的局域网传文件工具，适合门店、办公室、家里同一 Wi‑Fi 下的快速拷贝：

- **电脑 ↔ 电脑**：发现附近设备，加密传输
- **手机扫码**：不用装 App，打开网页即可收发
- **门店码**：顾客把文件发到店里电脑（打印 / 拷贝场景）

### 平台
| 平台 | 技术 | 说明 |
|------|------|------|
| macOS 14+ | Swift / SwiftUI（`Package.swift`） | `scripts/build.sh` → `.build/互传.app` |
| Windows | Go + WebView2（`win/`） | `scripts/build-win.sh` |
| Linux | Go（amd64 / arm64） | `scripts/build-linux.sh`，见 `linux/用法.txt` |

### 下载
- 官网：<https://www.ak129.cn/huchuan/>
- GitHub Release（域外推荐）：<https://github.com/akchansun/AirLink-Go/releases/tag/v1.0.0>
- Gitee Release：<https://gitee.com/akcg/AirLink-Go/releases/tag/v1.0.0>
  - macOS：`AirLinkGo-1.0.0-macos.zip`
  - Windows：`AirLinkGo-1.0.0-windows-amd64.exe`
  - Linux amd64 / arm64：见 Release 附件

### 编译（macOS）

```bash
zsh scripts/build.sh
```

依赖：Xcode Command Line Tools / Swift 5.9+。产物在 `.build/互传.app`。

### 编译（Windows）

在装有 Go 与 WebView2 运行时的环境中：

```bash
zsh scripts/build-win.sh
# 或进入 win/ 后按脚本等价命令自行 go build
```

### 编译（Linux）

```bash
zsh scripts/build-linux.sh
```

### 许可证
MIT，见 [LICENSE](LICENSE)。`win/third_party/go-qrcode` 为上游 MIT 依赖（见其 LICENSE）。

---

## English

### What it is
**互传 (HuChuan)** — English product name **AirLink Go** (repo: AirLink-Go) — is a free, open-source LAN file transfer tool:

- PC ↔ PC discovery and encrypted transfer on the same network
- Phone browser via QR code (no app install)
- Optional “store booth” QR for sending files to a shop PC

### Download
- Website: <https://www.ak129.cn/huchuan/>
- GitHub Release: <https://github.com/akchansun/AirLink-Go/releases/tag/v1.0.0>
- Gitee Release: <https://gitee.com/akcg/AirLink-Go/releases/tag/v1.0.0>

### Platforms
- **macOS 14+**: Swift package (`Package.swift`), build with `zsh scripts/build.sh`
- **Windows**: Go + WebView2 under `win/`
- **Linux**: Go amd64/arm64 via `scripts/build-linux.sh`

### License
MIT — see [LICENSE](LICENSE).
