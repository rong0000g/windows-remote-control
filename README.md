# windows-remote-control

一个 Claude skill：把电视盒子、投影仪等蓝牙遥控器变成 Windows 电脑的遥控器。不改遥控器硬件，也不影响实体键盘。

它带着 Claude 按步骤走：判断遥控器是红外还是蓝牙、配对、读取真实键码、查应用快捷键、设计每个应用的按键、安全测试和开机自启。

## 包含什么

| 路径 | 内容 |
|---|---|
| `SKILL.md` | Claude 使用的流程说明 |
| `scripts/remote-control.ahk` | 可运行的 AutoHotkey v2 脚本：应用菜单、遥控模式、应用内按键、设置窗口 |
| `scripts/dictate.cs` | 语音输入：读取遥控器自带麦克风的音频，用本机 SenseVoice 或可选的云端 API 识别 |
| `scripts/asr/asr_worker.py` | 本机识别进程，用时才加载模型 |
| `scripts/setup-asr.ps1` | 下载本机识别的模型和运行库 |
| `tools/` | 按键记录、音频抓包和解码、后台窗口截图、蓝牙通道探测和扫描小工具 |
| `references/` | 踩坑记录、测试方法、一个完整示例 |

## 安装 skill

把整个文件夹放到 `~/.claude/skills/windows-remote-control/`，然后告诉 Claude 你想用遥控器控制电脑。

## 直接运行脚本

需要 Windows 10 和 [AutoHotkey v2](https://www.autohotkey.com/)。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build.ps1
```

然后双击 `scripts\remote-control.ahk`，双击 `scripts\按键设置.ahk` 可以修改设置。

要用语音输入，还需要 Python，并运行一次下面的命令。它会下载约 155MB 的模型和约 18MB 的运行库，解压后约占 270MB：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-asr.ps1
```

用法是按住语音键说话，松开后出字。模型第一次用时才加载，约占 350MB 内存，闲置 5 分钟后自动释放。升级 Python 后要重新运行这个命令。

**脚本里的键码、窗口坐标和应用列表都来自作者的设备**，详见 `references/example-x500.md`。其他遥控器要先用 `tools\keylog.exe` 读取真实键码，并按自己的窗口重新测量坐标。音频格式也只在这一款遥控器上验证过，其他语音遥控器可能不同。

## 隐私

- 日志只记录键名、音频时长、字数和执行结果，不记录输入或识别的文字。
- 默认在本机识别，录音不出电脑，临时音频识别后删除。
- 云端语音默认关闭。开启后录音会上传给你选择的服务商，并按其价格计费。
- API Key 用 Windows DPAPI 加密保存在本机。`keymap.ini`、日志、密钥文件、录音和截图已被 `.gitignore` 排除。
