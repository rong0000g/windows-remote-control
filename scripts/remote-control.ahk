#Requires AutoHotkey v2.0
#SingleInstance Force

; 坚影 X500 遥控器 -> ChatGPT 桌面版
; 真实键码（已实测）：方向键、OK=Enter、菜单=AppsKey、设置=F2、信号源=F1、F+=F5、F-=F6、中间键=F16、语音=F24
; 两层用法：
;   菜单键打开应用列表，↑↓ 选择，OK 打开，不需要遥控模式。
;   中间键开关“遥控模式”，模式内方向键等控制 ChatGPT。
; 遥控器与实体键盘的方向键等键码相同，所以只在列表打开或遥控模式内接管，平时实体键盘不受影响。
; 应用列表和按键功能保存在同目录的 keymap.ini，用“按键设置”窗口修改。

TARGET := "ahk_exe ChatGPT.exe"
APP_ID := "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
IDLE_MS := 120000
SEARCH_MS := 20000
PICK_MS := 15000
CONFIG := A_ScriptDir "\keymap.ini"
DEBUG_LOG := A_ScriptDir "\keys-debug.log"
DICTATION := "语音输入"
DICTATE_EXE := A_ScriptDir "\dictate.exe"
DICTATE_ARGS := ""
DICTATE_EVENT := "Local\RemoteControlDictationToggle"
VOICE_KEY := A_ScriptDir "\voice-key.bin"
VOICE_LOCAL := "本机离线"
VOICE_PROVIDERS := Map(
    VOICE_LOCAL, {url: "", model: ""},
    "OpenAI", {url: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe"},
    "硅基流动", {url: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"},
    "自定义", {url: "", model: ""}
)
VOICE_ORDER := [VOICE_LOCAL, "OpenAI", "硅基流动", "自定义"]
OPEN_APP := "打开程序/文件夹/网址"
CHATGPT_ITEM := "ChatGPT"
DEFAULT_APPS := [CHATGPT_ITEM, "微信", "Google Chrome", "Claude", "Grok Bot","Word", "Excel", "StataNow 19 MP", "Cursor", "File Explorer", "카카오톡"]

global remoteMode := false
global searchOpen := false
global pickerOpen := false
global pickIndex := 1
global pickFirst := 1
global appList := []
global listening := false
global dictatePid := 0
global dictateQueue := []
global debugPending := ""

ACTIONS := Map(
    "上一个对话", {chat: true, param: "", run: (k) => Send("^![")},
    "下一个对话", {chat: true, param: "", run: (k) => Send("^!]")},
    "返回", {chat: true, param: "", run: (k) => Send("^[")},
    "前进", {chat: true, param: "", run: (k) => Send("^]")},
    "打开搜索", {chat: true, param: "", run: OpenSearch},
    "搜索确认", {chat: true, param: "", run: (k) => ShowStatus("OK 未生效：搜索框没打开")},
    "新聊天", {chat: true, param: "", run: (k) => Send("^n")},
    "取消或退出", {chat: false, param: "", run: Cancel},
    "打开ChatGPT", {chat: false, param: "", run: OpenApp},
    OPEN_APP, {chat: false, param: "路径或网址", run: RunParam},
    "发送按键", {chat: false, param: "如 ^n", run: (k) => Send(k.param)},
    "页面上滚", {chat: false, param: "", run: (k) => ScrollPage("Up")},
    "页面下滚", {chat: false, param: "", run: (k) => ScrollPage("Down")},
    "音量增大", {chat: false, param: "", run: (k) => Send("{Volume_Up 3}")},
    "音量减小", {chat: false, param: "", run: (k) => Send("{Volume_Down 3}")},
    "播放暂停", {chat: false, param: "", run: (k) => Send("{Media_Play_Pause}")},
    "浏览器全屏", {chat: false, param: "", run: (k) => Send("{F11}")},
    "视频全屏", {chat: false, param: "", run: (k) => ToggleVideoFullscreen()},
    "切换网页", {chat: false, param: "", run: (k) => Send("^{Tab}")},
    "微信-上", {chat: false, param: "", run: (k) => WxMove(0, -1)},
    "微信-下", {chat: false, param: "", run: (k) => WxMove(0, 1)},
    "微信-左", {chat: false, param: "", run: (k) => WxMove(-1, 0)},
    "微信-右", {chat: false, param: "", run: (k) => WxMove(1, 0)},
    "微信-确认", {chat: false, param: "", run: (k) => WxConfirm()},
    "Grok-上", {chat: false, param: "", run: (k) => GrokMove(0, -1)},
    "Grok-下", {chat: false, param: "", run: (k) => GrokMove(0, 1)},
    "Grok-左", {chat: false, param: "", run: (k) => GrokMove(-1, 0)},
    "Grok-语音聊天", {chat: false, param: "", run: (k) => GrokMove(1, 0)},
    "Grok-确认", {chat: false, param: "", run: (k) => GrokConfirm()},
    "ChatGPT-上", {chat: false, param: "", run: (k) => GptMove(0, -1)},
    "ChatGPT-下", {chat: false, param: "", run: (k) => GptMove(0, 1)},
    "ChatGPT-删除文字", {chat: false, param: "", run: (k) => GptMove(-1, 0)},
    "ChatGPT-切换模型", {chat: false, param: "", run: (k) => GptMove(1, 0)},
    "ChatGPT-确认", {chat: false, param: "", run: (k) => GptConfirm()},
    "ChatGPT-返回", {chat: false, param: "", run: (k) => GptBack()},
    "ChatGPT-新建对话", {chat: false, param: "", run: (k) => GptNew()},
    "Claude-上", {chat: false, param: "", run: (k) => ClaudeMove(-1)},
    "Claude-下", {chat: false, param: "", run: (k) => ClaudeMove(1)},
    "Claude-删除文字", {chat: false, param: "", run: (k) => ClaudeDelete()},
    "Claude-确认", {chat: false, param: "", run: (k) => ClaudeConfirm()},
    "Claude-返回", {chat: false, param: "", run: (k) => ClaudeBack()},
    "Claude-新建对话", {chat: false, param: "", run: (k) => ClaudeNew()},
    "不使用", {chat: true, param: "", run: (k) => 0}
)
ACTION_ORDER := ["上一个对话", "下一个对话", "返回", "前进", "打开搜索", "搜索确认", "新聊天", "取消或退出",
    "打开ChatGPT", OPEN_APP, "发送按键", "页面上滚", "页面下滚", "音量增大", "音量减小", "播放暂停", "视频全屏", "浏览器全屏", "切换网页", "微信-上", "微信-下", "微信-左", "微信-右", "微信-确认",
    "Grok-上", "Grok-下", "Grok-左", "Grok-语音聊天", "Grok-确认",
    "ChatGPT-上", "ChatGPT-下", "ChatGPT-删除文字", "ChatGPT-切换模型", "ChatGPT-确认", "ChatGPT-返回", "ChatGPT-新建对话",
    "Claude-上", "Claude-下", "Claude-删除文字", "Claude-确认", "Claude-返回", "Claude-新建对话", "不使用"]

; 遥控模式内的功能
KEYS := [
    {id: "Up", hk: "Up", name: "↑", native: "{Up}", def: "上一个对话", defParam: ""},
    {id: "Down", hk: "Down", name: "↓", native: "{Down}", def: "下一个对话", defParam: ""},
    {id: "Left", hk: "Left", name: "←", native: "{Left}", def: "返回", defParam: ""},
    {id: "Right", hk: "Right", name: "→", native: "{Right}", def: "前进", defParam: ""},
    {id: "OK", hk: "Enter", name: "OK", native: "{Enter}", def: "搜索确认", defParam: ""},
    {id: "Settings", hk: "F2", name: "设置", native: "{F2}", def: "取消或退出", defParam: ""},
    {id: "Source", hk: "F1", name: "信号源", native: "{F1}", def: "打开ChatGPT", defParam: ""},
    {id: "FPlus", hk: "F5", name: "F+", native: "{F5}", def: "打开搜索", defParam: ""},
    {id: "FMinus", hk: "F6", name: "F-", native: "{F6}", def: "不使用", defParam: ""},
    {id: "Voice", hk: "F24", name: "语音键", native: "{F24}", def: DICTATION, defParam: ""}
]

; 应用内按键：遥控模式下，这些应用在前台时用自己的一套功能，其余应用用上面的默认功能。
PROFILES := Map("chrome.exe", MakeProfile("谷歌浏览器", "Chrome", Map(
    "Up", "页面上滚",
    "Down", "页面下滚",
    "Left", "音量减小",
    "Right", "音量增大",
    "OK", "播放暂停",
    "Source", "视频全屏",
    "Settings", "切换网页"
)), "Weixin.exe", MakeProfile("微信", "Weixin", Map(
    "Up", "微信-上",
    "Down", "微信-下",
    "Left", "微信-左",
    "Right", "微信-右",
    "OK", "微信-确认"
)), "Grok Bot.exe", MakeProfile("Grok Bot", "Grok", Map(
    "Up", "Grok-上",
    "Down", "Grok-下",
    "Left", "Grok-左",
    "Right", "Grok-语音聊天",
    "OK", "Grok-确认"
)), "ChatGPT.exe", MakeProfile("ChatGPT", "Gpt", Map(
    "Up", "ChatGPT-上",
    "Down", "ChatGPT-下",
    "Left", "ChatGPT-删除文字",
    "Right", "ChatGPT-切换模型",
    "OK", "ChatGPT-确认",
    "Settings", "ChatGPT-返回",
    "Source", "ChatGPT-新建对话"
)), "claude.exe", MakeProfile("Claude", "Claude", Map(
    "Up", "Claude-上",
    "Down", "Claude-下",
    "Left", "Claude-删除文字",
    "OK", "Claude-确认",
    "Settings", "Claude-返回",
    "Source", "Claude-新建对话"
)))

MakeProfile(label, prefix, defaults) {
    entries := [], byKey := Map()
    for k in KEYS {
        if k.id = "Voice"
            continue
        entry := {id: prefix "_" k.id, name: k.name, def: defaults.Has(k.id) ? defaults[k.id] : "不使用", defParam: ""}
        entries.Push(entry)
        byKey[k.id] := entry
    }
    return {label: label, entries: entries, byKey: byKey}
}

ActiveProfile() {
    for exe, profile in PROFILES
        if WinActive("ahk_exe " exe)
            return profile
    return 0
}

overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
overlay.BackColor := "1F6FEB"
overlay.SetFont("s12 cWhite", "Microsoft YaHei UI")
overlayText := overlay.Add("Text", "w300 h28 Center", "")

; 分层窗口：内容由 GDI+ 绘制，支持圆角和半透明阴影。
picker := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x80000", "应用选择")

; 用实体键盘打字时立即退出接管，避免方向键和 Enter 继续被占用。
typingWatch := InputHook("V I")
typingWatch.OnChar := (*) => SetMode(false)
pickWatch := InputHook("V I")
pickWatch.OnChar := (*) => ClosePicker()

LoadConfig()
if A_Args.Length >= 2 && A_Args[1] = "--preview" {
    pickIndex := A_Args.Length >= 3 ? Integer(A_Args[3]) : 1
    pickFirst := Max(1, pickIndex - MaxRows() + 1)
    SaveBitmapPng(RenderPicker(), A_Args[2])
    ExitApp()
}
RegisterKeys()
OnMessage(0x4A, OnDictation)
OnExit(StopDictationProcess)
OnExit(FlushLog)
RotateLog()
StartDictationProcess()
A_TrayMenu.Add()
A_TrayMenu.Add("按键设置", OpenSettings)
A_TrayMenu.Default := "按键设置"
A_IconTip := "遥控器按键"
if A_Args.Length && A_Args[1] = "--settings"
    OpenSettings()

LoadConfig() {
    global appList := []
    for k in KEYS
        LoadEntry(k)
    for exe, profile in PROFILES
        for entry in profile.entries
            LoadEntry(entry)
    count :=Integer(IniRead(CONFIG, "AppList", "count", 0))
    Loop count {
        item := IniRead(CONFIG, "AppList", "item" A_Index, "")
        if item != ""
            appList.Push(item)
    }
    if !appList.Length
        for item in DEFAULT_APPS
            appList.Push(item)
}

LoadEntry(k) {
    k.action := IniRead(CONFIG, k.id, "action", k.def)
    k.param := IniRead(CONFIG, k.id, "param", k.defParam)
    if !(ACTIONS.Has(k.action) || (k.id = "Voice" && k.action = DICTATION)) {
        k.action := k.def
        k.param := k.defParam
    }
}

RegisterKeys() {
    ; 列表的热键先注册，列表打开时优先于遥控模式。
    HotIf((*) => pickerOpen)
    Hotkey("$Up", (*) => PickMove(-1))
    Hotkey("$Down", (*) => PickMove(1))
    Hotkey("$Enter", PickConfirm)
    Hotkey("$F2", (*) => ClosePicker())
    for hk in ["Left", "Right", "F1", "F5", "F6"]
        Hotkey("$" hk, PickIgnore)
    HotIf((*) => remoteMode)
    for k in KEYS
        if k.id != "Voice"
            Hotkey("$" k.hk, RunKey.Bind(k))
    HotIf()
    Hotkey("$AppsKey", TogglePicker)
    Hotkey("F16", CenterKey)
    ; 语音键实体键盘没有，不需要遥控模式。
    voice := KEYS[KEYS.Length]
    if voice.action = DICTATION
        Hotkey("$F24", ToggleDictation)
    else
        Hotkey("$F24", RunKey.Bind(voice))
}

CenterKey(*) {
    if pickerOpen {
        ClosePicker()
        return
    }
    SetMode(!remoteMode)
    DebugLog("中间键 -> 遥控模式=" (remoteMode ? "开" : "关"))
}

; ===== 语音输入 =====
; dictate.exe 用本机中文语音识别，文字直接输入到当前光标处，不会自动发送。

StartDictationProcess() {
    global dictatePid
    if !FileExist(DICTATE_EXE) {
        DebugLog("语音程序不存在")
        return
    }
    try Run('"' DICTATE_EXE '" ' A_ScriptHwnd ' --config "' CONFIG '" --key "' VOICE_KEY '" ' DICTATE_ARGS, , "Hide", &dictatePid)
}

; 用当前 Windows 账户加密后保存 API Key，文件里没有明文。
SaveVoiceKey(plain) {
    n := StrPut(plain, "UTF-8") - 1
    data := Buffer(n + 1)
    StrPut(plain, data, "UTF-8")
    input := Buffer(16, 0), output := Buffer(16, 0)
    NumPut("uint", n, input, 0)
    NumPut("ptr", data.Ptr, input, 8)
    if !DllCall("crypt32\CryptProtectData", "ptr", input, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", output)
        throw Error("加密失败")
    size := NumGet(output, 0, "uint"), ptr := NumGet(output, 8, "ptr")
    file := FileOpen(VOICE_KEY, "w")
    file.RawWrite(ptr, size)
    file.Close()
    DllCall("LocalFree", "ptr", ptr)
}

StopDictationProcess(*) {
    if dictatePid
        try ProcessClose(dictatePid)
}

ToggleDictation(*) {
    DebugLog("语音键 -> " (listening ? "结束" : "开始"))
    if !listening
        ShowStatus("正在启动语音…")
    h := DllCall("OpenEventW", "uint", 0x0002, "int", 0, "wstr", DICTATE_EVENT, "ptr")
    if !h {
        DebugLog("语音程序没有运行")
        ShowStatus("语音程序没有运行，正在重启")
        StartDictationProcess()
        return
    }
    DllCall("SetEvent", "ptr", h)
    DllCall("CloseHandle", "ptr", h)
}

; WM_COPYDATA 里不能发送按键，先放进队列再由定时器输入。
OnDictation(wParam, lParam, msg, hwnd) {
    global listening
    data := StrGet(NumGet(lParam, 2 * A_PtrSize, "ptr"), "UTF-16")
    kind := SubStr(data, 1, 1), text := SubStr(data, 2)
    switch kind {
        case "S":
            listening := true
            DebugLog("语音 -> 已开始")
            ShowStatus("正在听…再按语音键结束")
        case "H":
            ShowStatus("正在听：" SubStr(text, -12))
        case "P":
            ShowStatus("正在识别…")
        case "W":
            DebugLog("云端识别失败：" text "，改用本机识别")
            ShowStatus("云端失败，改用本机识别")
        case "T":
            dictateQueue.Push(text)
            SetTimer(FlushDictation, -1)
        case "D":
            listening := false
            DebugLog("语音 -> 已结束")
            ShowStatus("语音输入结束")
        case "E":
            listening := false
            DebugLog("语音失败：" text)
            ShowStatus("语音启动失败，检查麦克风")
    }
    return true
}

FlushDictation() {
    while dictateQueue.Length {
        text := dictateQueue.RemoveAt(1)
        SendText(text)
        DebugLog("语音 -> 已输入 " StrLen(text) " 字")
    }
}

; ===== 应用列表 =====

TogglePicker(*) {
    global pickerOpen, pickIndex, pickFirst
    if pickerOpen {
        ClosePicker()
        return
    }
    pickIndex := 1
    pickFirst := 1
    pickerOpen := true
    pickWatch.Start()
    SetTimer(ClosePicker, -PICK_MS)
    DebugLog("菜单 -> 打开列表")
    DrawPicker(true)
}

ClosePicker() {
    global pickerOpen := false
    SetTimer(ClosePicker, 0)
    pickWatch.Stop()
    picker.Hide()
}

PickIgnore(*) => SetTimer(ClosePicker, -PICK_MS)

PickMove(step) {
    global pickIndex, pickFirst
    SetTimer(ClosePicker, -PICK_MS)
    n := appList.Length
    pickIndex := Mod(pickIndex - 1 + step + n, n) + 1
    if pickIndex < pickFirst
        pickFirst := pickIndex
    if pickIndex >= pickFirst + MaxRows()
        pickFirst := pickIndex - MaxRows() + 1
    DrawPicker(false)
}

PickConfirm(*) {
    item := appList[pickIndex]
    ClosePicker()
    DebugLog("列表 -> " item)
    ShowStatus("打开：" DisplayName(item))
    try {
        if item = CHATGPT_ITEM
            OpenApp(0)
        else
            RunParam({param: item})
    } catch as e {
        DebugLog("失败：" e.Message)
        ShowStatus("打不开：" DisplayName(item))
    }
    SetTimer(AutoRemoteMode, -500)
}

; 从列表打开有专属按键的应用后自动进入遥控模式，不用再按中间键。打字时仍会自动退出。
AutoRemoteMode() {
    if !remoteMode && ActiveProfile() {
        SetMode(true)
        DebugLog("自动进入遥控模式")
    }
}

DisplayName(item) {
    if RegExMatch(item, "[\\/]")
        SplitPath(item, &item)
    return item
}

; ===== 绘制 =====

MaxRows() => 7

Px(v) => Round(v * A_ScreenDPI / 96)

; 按系统浅色/深色主题取色，配色接近 Apple 的系统色。
Palette() {
    static light := {panel: 0xF7FAFAFC, text: 0xFF1D1D1F, sub: 0xFF6E6E73, accent: 0xFF007AFF, selText: 0xFFFFFFFF, line: 0x14000000, thumb: 0x40000000}
    static dark := {panel: 0xF71E1E20, text: 0xFFF5F5F7, sub: 0xFF98989D, accent: 0xFF0A84FF, selText: 0xFFFFFFFF, line: 0x1FFFFFFF, thumb: 0x50FFFFFF}
    isLight := 1
    try isLight := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme")
    return isLight ? light : dark
}

GdipInit() {
    static token := 0
    if token
        return
    DllCall("LoadLibrary", "str", "gdiplus.dll", "ptr")
    si := Buffer(24, 0)
    NumPut("uint", 1, si)
    DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si, "ptr", 0)
}

RoundPath(x, y, w, h, r) {
    p := 0
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &p)
    d := r * 2
    for arc in [[x, y, 180], [x + w - d, y, 270], [x + w - d, y + h - d, 0], [x, y + h - d, 90]]
        DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", arc[1], "float", arc[2], "float", d, "float", d, "float", arc[3], "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", p)
    return p
}

FillRound(g, x, y, w, h, r, argb) {
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush)
    p := RoundPath(x, y, w, h, r)
    DllCall("gdiplus\GdipFillPath", "ptr", g, "ptr", brush, "ptr", p)
    DllCall("gdiplus\GdipDeletePath", "ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
}

; align: 0 左对齐，1 居中。style: 0 常规，1 粗体。
DrawText(g, text, x, y, w, h, sizePx, style, argb, align := 0) {
    static fonts := Map(), fmt := 0
    key := sizePx "|" style
    if !fonts.Has(key) {
        fam := 0, font := 0
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Microsoft YaHei UI", "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", sizePx, "int", style, "int", 2, "ptr*", &font)
        DllCall("gdiplus\GdipDeleteFontFamily", "ptr", fam)
        fonts[key] := font
    }
    if !fmt {
        DllCall("gdiplus\GdipCreateStringFormat", "int", 0x1000, "ushort", 0, "ptr*", &fmt)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", 1)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "ptr", fmt, "int", 3)
    }
    DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", align)
    rect := Buffer(16)
    NumPut("float", x, "float", y, "float", w, "float", h, rect)
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &brush)
    DllCall("gdiplus\GdipDrawString", "ptr", g, "wstr", text, "int", -1, "ptr", fonts[key], "ptr", rect, "ptr", fmt, "ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
}

; 取应用的 48px 图标并保留透明通道，失败时返回 0。
IconBitmap(item) {
    static cache := Map()
    if cache.Has(item)
        return cache[item]
    apps := InstalledApps()
    source := item = CHATGPT_ITEM && apps.Has("Codex") ? apps["Codex"] : (apps.Has(item) ? apps[item] : item)
    bmp := 0
    try bmp := LoadIcon48(source)
    cache[item] := bmp
    return bmp
}

LoadIcon48(path) {
    sfi := Buffer(696, 0)
    if !DllCall("shell32\SHGetFileInfoW", "wstr", path, "uint", 0, "ptr", sfi, "uint", sfi.Size, "uint", 0x4000, "ptr")
        return 0
    index := NumGet(sfi, 8, "int")
    iid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", "{46EB5926-582E-4017-9FDF-E8998DAA0950}", "ptr", iid)
    list := 0
    if DllCall("shell32\SHGetImageList", "int", 2, "ptr", iid, "ptr*", &list) != 0
        return 0
    hicon := 0
    ComCall(10, list, "int", index, "uint", 1, "ptr*", &hicon)
    ObjRelease(list)
    if !hicon
        return 0
    bmp := IconToBitmap(hicon)
    DllCall("DestroyIcon", "ptr", hicon)
    return bmp
}

; GdipCreateBitmapFromHICON 会丢失部分图标的透明度，所以直接读取图标位图的 ARGB 像素。
IconToBitmap(hicon) {
    info := Buffer(32, 0)
    DllCall("GetIconInfo", "ptr", hicon, "ptr", info)
    hbmMask := NumGet(info, 16, "ptr")
    hbmColor := NumGet(info, 24, "ptr")
    bm := Buffer(32, 0)
    DllCall("GetObject", "ptr", hbmColor, "int", bm.Size, "ptr", bm)
    w := NumGet(bm, 4, "int"), h := NumGet(bm, 8, "int")
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0), NumPut("int", w, bi, 4), NumPut("int", -h, bi, 8)
    NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
    pixels := Buffer(w * h * 4, 0)
    hdc := DllCall("GetDC", "ptr", 0, "ptr")
    DllCall("GetDIBits", "ptr", hdc, "ptr", hbmColor, "uint", 0, "uint", h, "ptr", pixels, "ptr", bi, "uint", 0)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
    bmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &bmp)
    gfx := 0
    src := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", w * 4, "int", 0x26200A, "ptr", pixels, "ptr*", &src)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", bmp, "ptr*", &gfx)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", gfx, "ptr", src, "int", 0, "int", 0, "int", w, "int", h)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", gfx)
    DllCall("gdiplus\GdipDisposeImage", "ptr", src)
    DllCall("DeleteObject", "ptr", hbmColor)
    DllCall("DeleteObject", "ptr", hbmMask)
    return bmp
}

; 没有图标的项目（如网址）画一个带首字的圆角方块。
DrawFallbackIcon(g, item, x, y, size, c) {
    FillRound(g, x, y, size, size, size * 0.22, 0xFF8E8E93)
    DrawText(g, SubStr(DisplayName(item), 1, 1), x, y, size, size, size * 0.5, 1, 0xFFFFFFFF, 1)
}

RenderPicker() {
    GdipInit()
    c := Palette()
    margin := Px(28), panelW := Px(440), rowH := Px(58), header := Px(58), footer := Px(46)
    rows := Min(MaxRows(), appList.Length)
    panelH := header + rows * rowH + footer
    w := panelW + margin * 2, h := panelH + margin * 2
    bmp := 0, g := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &bmp)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", bmp, "ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", g, "int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", g, "int", 4)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)
    radius := Px(22)
    ; 柔和阴影：由外向内叠加多层低透明度圆角矩形，并略微下移。
    Loop 14 {
        grow := Px(15 - A_Index)
        FillRound(g, margin - grow, margin - grow + Px(6), panelW + grow * 2, panelH + grow * 2, radius + grow, 0x09000000)
    }
    FillRound(g, margin, margin, panelW, panelH, radius, c.panel)
    left := margin + Px(14), inner := panelW - Px(28)
    DrawText(g, "打开应用", left + Px(8), margin + Px(10), inner, header - Px(14), Px(20), 1, c.text)
    icon := Px(38)
    Loop rows {
        i := pickFirst + A_Index - 1
        item := appList[i]
        y := margin + header + (A_Index - 1) * rowH
        selected := i = pickIndex
        if selected
            FillRound(g, left, y + Px(2), inner, rowH - Px(4), Px(14), c.accent)
        ix := left + Px(10), iy := y + (rowH - icon) // 2
        ibmp := IconBitmap(item)
        ; ChatGPT 的图标是白色，需要黑色底才看得清。
        if item = CHATGPT_ITEM
            FillRound(g, ix, iy, icon, icon, icon * 0.22, 0xFF000000)
        if ibmp
            DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", ibmp, "int", ix, "int", iy, "int", icon, "int", icon)
        else
            DrawFallbackIcon(g, item, ix, iy, icon, c)
        tx := ix + icon + Px(14)
        DrawText(g, DisplayName(item), tx, y, left + inner - tx - Px(10), rowH, Px(17), 0, selected ? c.selText : c.text)
    }
    ; 列表超出可见行数时显示细滚动条。
    if appList.Length > rows {
        trackY := margin + header + Px(4), trackH := rows * rowH - Px(8)
        thumbH := Max(Px(24), trackH * rows // appList.Length)
        thumbY := trackY + (trackH - thumbH) * (pickFirst - 1) // (appList.Length - rows)
        FillRound(g, margin + panelW - Px(9), thumbY, Px(4), thumbH, Px(2), c.thumb)
    }
    DrawText(g, "↑ ↓ 选择    OK 打开    菜单 关闭", margin, margin + panelH - footer, panelW, footer - Px(4), Px(13), 0, c.sub, 1)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)
    return bmp
}

DrawPicker(fadeIn) {
    bmp := RenderPicker()
    w := 0, h := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", bmp, "uint*", &w)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", bmp, "uint*", &h)
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", bmp, "ptr*", &hbm, "uint", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    x := (A_ScreenWidth - w) // 2, y := (A_ScreenHeight - h) // 2
    if fadeIn
        picker.Show("NA x" x " y" y " w" w " h" h)
    hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
    hdcMem := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    old := DllCall("SelectObject", "ptr", hdcMem, "ptr", hbm, "ptr")
    if fadeIn
        for alpha in [90, 170, 225]
            UpdateLayer(hdcScreen, hdcMem, x, y, w, h, alpha), Sleep(14)
    UpdateLayer(hdcScreen, hdcMem, x, y, w, h, 255)
    DllCall("SelectObject", "ptr", hdcMem, "ptr", old)
    DllCall("DeleteDC", "ptr", hdcMem)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    DllCall("DeleteObject", "ptr", hbm)
}

UpdateLayer(hdcScreen, hdcMem, x, y, w, h, alpha) {
    pos := Buffer(8), size := Buffer(8), src := Buffer(8, 0), blend := Buffer(4, 0)
    NumPut("int", x, "int", y, pos)
    NumPut("int", w, "int", h, size)
    NumPut("uchar", 0, "uchar", 0, "uchar", alpha, "uchar", 1, blend)
    DllCall("UpdateLayeredWindow", "ptr", picker.Hwnd, "ptr", hdcScreen, "ptr", pos, "ptr", size, "ptr", hdcMem, "ptr", src, "uint", 0, "ptr", blend, "uint", 2)
}

SaveBitmapPng(bmp, path) {
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "ptr", bmp, "wstr", path, "ptr", clsid, "ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
}

; ===== 遥控模式 =====

RunAction(k, action) {
    try
        action.run.Call(k)
    catch as e {
        DebugLog("失败：" e.Message)
        ShowStatus("执行失败：" k.name)
    }
}

; 只记录遥控器键名和执行结果，不记录任何文字内容，用于排查按键没生效的原因。
; 写文件每次约 13 毫秒，所以先放进内存，稍后在按键间隙写入。
DebugLog(text) {
    global debugPending .= FormatTime(, "HH:mm:ss") " " text "`n"
    SetTimer(FlushLog, -500)
}

FlushLog(*) {
    global debugPending
    if debugPending = ""
        return
    text := debugPending
    debugPending := ""
    try FileAppend(text, DEBUG_LOG, "UTF-8")
}

; 启动时日志超过 1MB 就改名为 .old，只保留一份旧日志。
RotateLog() {
    try {
        if FileExist(DEBUG_LOG) && FileGetSize(DEBUG_LOG) > 1048576
            FileMove(DEBUG_LOG, DEBUG_LOG ".old", 1)
    }
}

RunKey(k, *) {
    ; 按键排队逐个执行。否则切换对话途中按 OK，可能在鼠标短暂经过聊天区时误判成发送，连按也会丢键。
    Critical("On")
    started := A_TickCount
    Touch("收到：" k.name)
    profile := ActiveProfile()
    if profile && profile.byKey.Has(k.id) {
        entry := profile.byKey[k.id]
        if entry.action != "不使用"
            RunAction(entry, ACTIONS[entry.action])
        DebugLog(profile.label " " k.name " -> " entry.action " | 脚本耗时 " (A_TickCount - started) "ms")
        return
    }
    active := WinActive(TARGET)
    DebugLog(k.name " -> " k.action " | ChatGPT在前台=" (active ? "是" : "否") " | 搜索=" (searchOpen ? "开" : "关"))
    ; 搜索框打开时方向键和 OK 固定用来选择结果，不走自定义功能。
    if searchOpen && active {
        switch k.id {
            case "Up", "Down":
                SetTimer(ClearSearch, -SEARCH_MS)
                Send(k.native)
                return
            case "Left", "Right":
                return
            case "OK":
                SetSearch(false)
                Send("{Enter}")
                return
        }
    }
    action := ACTIONS[k.action]
    if action.chat && !active {
        Send(k.native)
        return
    }
    RunAction(k, action)
}

; 从开始菜单和桌面收集已安装应用：显示名 -> 快捷方式路径。
InstalledApps() {
    static apps := 0
    if apps
        return apps
    apps := Map()
    apps.CaseSense := false
    skip := "i)卸载|uninstall|help|帮助|documentation|faq|release notes|website|readme|manuals|module docs|修复|repair"
    for root in [A_Programs, A_ProgramsCommon, A_Desktop, A_DesktopCommon] {
        Loop Files root "\*.lnk", "R" {
            name := SubStr(A_LoopFileName, 1, -4)
            if !RegExMatch(name, skip) && !apps.Has(name)
                apps[name] := A_LoopFileFullPath
        }
    }
    return apps
}

AppNames() {
    list := ""
    for name in InstalledApps()
        list .= name "`n"
    names := []
    Loop Parse Sort(RTrim(list, "`n")), "`n"
        names.Push(A_LoopField)
    return names
}

; 应用已经打开就切到它的窗口，否则启动它。资源管理器进程常驻，始终新开窗口。
ActivateOrRun(exe, launch) {
    SplitPath(exe, &name, , &ext)
    if ext = "exe" && name != "explorer.exe" && WinExist("ahk_exe " name) {
        BringToFront("ahk_exe " name)
        return
    }
    ; 微信关到托盘后没有可见窗口，这时再运行快捷方式会多开一个登录框，所以直接恢复隐藏的主窗口。
    if name = "Weixin.exe" && ProcessExist(name) {
        hidden := HiddenMainWindow(name)
        if hidden {
            DetectHiddenWindows(true)
            WinShow(hidden)
            DetectHiddenWindows(false)
            BringToFront("ahk_id " hidden)
            DebugLog("已恢复隐藏窗口：" name)
            return
        }
    }
    Run(launch)
}

; 该程序最大的隐藏窗口，用来区分主窗口和各种辅助窗口。
HiddenMainWindow(exe) {
    DetectHiddenWindows(true)
    best := 0, bestArea := 0
    for h in WinGetList("ahk_exe " exe) {
        try {
            if DllCall("IsWindowVisible", "ptr", h) || WinGetTitle(h) = "" || (WinGetExStyle(h) & 0x80)
                continue
            WinGetPos(, , &w, &hh, h)
            if w >= 400 && hh >= 300 && w * hh > bestArea
                best := h, bestArea := w * hh
        }
    }
    DetectHiddenWindows(false)
    return best
}

; 切换后确认窗口真的到了前台；没到就用 Alt 键解除系统的前台限制再试一次，并记录结果。
BringToFront(win) {
    WinActivate(win)
    if WinWaitActive(win, , 0.5) {
        DebugLog("切换成功：" win)
        return
    }
    blocker := ForegroundInfo()
    Send("{Alt}")
    WinActivate(win)
    active := WinWaitActive(win, , 0.5)
    method := "Alt"
    if !active {
        DllCall("SwitchToThisWindow", "ptr", WinExist(win), "int", 1)
        active := WinWaitActive(win, , 0.5)
        method := "SwitchToThisWindow"
    }
    if !active {
        ; 最后的办法：最小化再还原，系统会把还原的窗口放到前面。
        target := WinExist(win)
        WinMinimize(target)
        Sleep(150)
        WinRestore(target)
        active := WinWaitActive(win, , 0.7)
        method := "最小化再还原"
    }
    DebugLog((active ? "重试后切换成功（" method "）：" : "切换失败：") win " | 挡住的窗口=" blocker)
    if !active
        ShowStatus("没能切到前台，再按一次试试")
}

; 包括隐藏窗口在内的真实前台窗口，只记录程序名和类名，用于排查切换失败。
ForegroundInfo() {
    DetectHiddenWindows(true)
    h := DllCall("GetForegroundWindow", "ptr")
    info := "无"
    if h {
        info := ""
        try info .= WinGetProcessName(h)
        try info .= " / " WinGetClass(h)
        info .= " / 可见=" DllCall("IsWindowVisible", "ptr", h)
    }
    DetectHiddenWindows(false)
    return info
}

; 多数视频网站用 f 键全屏。这些网站（按窗口标题识别）不响应 f，要双击画面，实测不会暂停。
VIDEO_DOUBLE_CLICK_SITES := ["酷播"]

ToggleVideoFullscreen() {
    title := WinGetTitle("A")
    for site in VIDEO_DOUBLE_CLICK_SITES {
        if InStr(title, site) {
            CoordMode("Mouse", "Screen")
            MouseGetPos(&mx, &my)
            WinGetPos(&x, &y, &w, &h, "A")
            Click(x + w // 2, y + h // 2, 2)
            Sleep(50)
            MouseMove(mx, my, 0)
            return
        }
    }
    Send("f")
}

; 滚轮作用在鼠标所在的窗口，所以鼠标不在当前窗口上时先移到窗口中央。
; 用滚轮而不是方向键，因为视频网站常把方向键用作快进和音量。
ScrollPage(direction) {
    CoordMode("Mouse", "Screen")
    hwnd := WinExist("A")
    under := 0
    MouseGetPos(, , &under)
    if DllCall("GetAncestor", "ptr", under, "uint", 2, "ptr") != hwnd {
        WinGetPos(&x, &y, &w, &h, hwnd)
        MouseMove(x + w // 2, y + h // 2, 0)
    }
    Send("{Wheel" direction " 3}")
}

; ===== 微信 =====
; 微信 4.x 的界面是自绘的，方向键不能选表情，所以用鼠标悬停表示当前选中项，悬停高亮就是实际目标。
; 当前区域看鼠标位置：在好友列表上时 ↑↓ 逐个切换好友并立刻打开对话；在聊天区时 ↑↓ 滑动聊天记录、OK 发送。
; 用鼠标点过哪个区域，遥控器就接着操作哪个区域。表情面板单独记为 emoji 状态。
; 坐标在 120 DPI 下实测，按窗口左上角和底边定位；拖动过好友列表的宽度后需要重新测量。
global wxState := "normal"
global wxCol := 0, wxEmojiRow := 0, wxMain := 0
WX :={listX: 235, listProbeX: 95, listTop: 137, listStep: 81.4, chatLeft: 384,
    emojiBtnX: 423, emojiBtnBottom: 51, smileyTabX: 237, smileyTabBottom: 104,
    cellX: 173, cellBottom: 466, cellStepX: 55.2, cellStepY: 55, cellCols: 10, cellRows: 6,
    composerBottom: 110}

WxScale(v) => Round(v * A_ScreenDPI / 120)

; 表情面板是独立的弹出窗口，打开后前台不再是主窗口，所以这时继续用记下的主窗口位置。
WxRect() {
    global wxMain
    if wxState != "emoji" || !wxMain || !WinExist(wxMain)
        wxMain := WinExist("A")
    WinGetPos(&x, &y, &w, &h, wxMain)
    return {x: x, y: y, w: w, h: h}
}

WxCellPoint(r) {
    return {x: r.x + WxScale(WX.cellX + wxCol * WX.cellStepX), y: r.y + r.h - WxScale(WX.cellBottom - wxEmojiRow * WX.cellStepY)}
}

WxMouseTo(px, py) {
    CoordMode("Mouse", "Screen")
    MouseMove(px, py, 0)
}

; 鼠标移到好友列表第一行，表示接下来操作好友列表。
WxHoverList(r) => WxMouseTo(r.x + WxScale(WX.listX), r.y + WxScale(WX.listTop))

WxMouseToChat(r) => WxMouseTo(r.x + (WxScale(WX.chatLeft) + r.w) // 2, r.y + r.h * 45 // 100)

WxWheel(direction) => Send("{Wheel" direction "}")

; 鼠标在好友列表上返回 "list"，在聊天区返回 "chat"，不在可操作区域返回 "outside"。
WxPane(r) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    if mx < r.x || mx >= r.x + r.w || my < r.y || my >= r.y + r.h
        return "outside"
    if mx < r.x + WxScale(WX.listProbeX)
        return "outside"
    return mx < r.x + WxScale(WX.chatLeft) ? "list" : "chat"
}

WxMove(dx, dy) {
    global wxState, wxCol, wxEmojiRow
    r := WxRect()
    if wxState = "emoji" {
        if dx < 0 && wxCol = 0 {
            Send("{Esc}")
            wxState := "normal"
            WxMouseToChat(r)
            ShowStatus("已关闭表情")
            return
        }
        if dx != 0 {
            wxCol := Min(WX.cellCols - 1, wxCol + dx)
        } else if (dy < 0 && wxEmojiRow = 0) || (dy > 0 && wxEmojiRow = WX.cellRows - 1) {
            p := WxCellPoint(r)
            WxMouseTo(p.x, p.y)
            WxWheel(dy < 0 ? "Up" : "Down")
            return
        } else {
            wxEmojiRow += dy
        }
        p := WxCellPoint(r)
        WxMouseTo(p.x, p.y)
        return
    }
    pane := WxPane(r)
    if dx < 0 {
        WxHoverList(r)
        ShowStatus("好友列表：↑↓ 切换好友")
    } else if dx > 0 {
        WxOpenEmoji(r)
    } else if pane = "chat" {
        WxMouseToChat(r)
        Loop 3
            WxWheel(dy < 0 ? "Up" : "Down")
    } else {
        WxStepFriend(r, dy)
    }
}

; 一次读取屏幕上一整列像素。逐点取色每次约 13 毫秒，切换一次好友要读上百个点，会慢约 2 秒。
ReadColumn(x, top, bottom) {
    h := bottom - top
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0), NumPut("int", 1, bi, 4), NumPut("int", -h, bi, 8)
    NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
    screen := DllCall("GetDC", "ptr", 0, "ptr")
    mem := DllCall("CreateCompatibleDC", "ptr", screen, "ptr")
    bits := 0
    bmp := DllCall("CreateDIBSection", "ptr", mem, "ptr", bi, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
    old := DllCall("SelectObject", "ptr", mem, "ptr", bmp, "ptr")
    DllCall("BitBlt", "ptr", mem, "int", 0, "int", 0, "int", 1, "int", h, "ptr", screen, "int", x, "int", top, "uint", 0x00CC0020)
    pixels := Buffer(h * 4)
    DllCall("RtlMoveMemory", "ptr", pixels, "ptr", bits, "uptr", h * 4)
    DllCall("SelectObject", "ptr", mem, "ptr", old)
    DllCall("DeleteObject", "ptr", bmp)
    DllCall("DeleteDC", "ptr", mem)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screen)
    return pixels
}

; 找到绿色的已选中行，返回它的中心纵坐标；当前没有选中行或已滑出可见范围时返回 0。
WxSelectedRowY(r) {
    top := r.y + WxScale(WX.listTop - 40)
    bottom := r.y + r.h - WxScale(10)
    pixels := ReadColumn(r.x + WxScale(WX.listProbeX), top, bottom)
    first := 0, last := 0
    y := top
    while y < bottom {
        color := NumGet(pixels, (y - top) * 4, "uint")
        red := (color >> 16) & 0xFF, green := (color >> 8) & 0xFF, blue := color & 0xFF
        if green > red + 40 && green > blue + 40 {
            first := first ? first : y
            last := y
        } else if first {
            break
        }
        y += WxScale(6)
    }
    return first ? (first + last) // 2 : 0
}

; 从已选中的好友移到上一个或下一个并点击，聊天窗口立刻切换。下一行不在可见范围时先滚动列表。
WxStepFriend(r, dy) {
    listX := r.x + WxScale(WX.listX)
    topLimit := r.y + WxScale(WX.listTop - 30)
    bottomLimit := r.y + r.h - WxScale(50)
    CoordMode("Mouse", "Screen")
    Loop 3 {
        current := WxSelectedRowY(r)
        if !current {
            ; 选中行不在可见范围时，打开当前能看到的第一行。
            WxHoverList(r)
            Sleep(40)
            Click()
            return
        }
        target := current + dy * WxScale(WX.listStep)
        if target >= topLimit && target <= bottomLimit {
            WxMouseTo(listX, target)
            Sleep(40)
            Click()
            return
        }
        WxMouseTo(listX, r.y + r.h // 2)
        Loop 2
            WxWheel(dy < 0 ? "Up" : "Down")
        Sleep(150)
    }
}

; 点开表情按钮后，用像素变化确认面板真的打开了，再点“普通表情”分类。
; 没打开时不继续点，否则会点到好友列表；收藏表情可能一点就发送，所以每次都切回普通表情。
WxOpenEmoji(r) {
    global wxState, wxCol, wxEmojiRow
    CoordMode("Pixel", "Screen")
    probes := []
    for offset in [[150, 300], [150, 376], [150, 420]]
        probes.Push({x: r.x + WxScale(offset[1]), y: r.y + r.h - WxScale(offset[2])})
    WxMouseTo(r.x + WxScale(WX.chatLeft) + 200, r.y + 60)
    Sleep(60)
    before := []
    for p in probes
        before.Push(PixelGetColor(p.x, p.y))
    CoordMode("Mouse", "Screen")
    Click(r.x + WxScale(WX.emojiBtnX), r.y + r.h - WxScale(WX.emojiBtnBottom))
    Sleep(400)
    changed := 0
    for i, p in probes
        changed += PixelGetColor(p.x, p.y) != before[i]
    if changed < 2 {
        DebugLog("微信：表情面板没有打开，变化点=" changed)
        ShowStatus("表情面板没打开，先打开一个对话")
        return
    }
    DebugLog("微信：表情面板已打开")
    Click(r.x + WxScale(WX.smileyTabX), r.y + r.h - WxScale(WX.smileyTabBottom))
    Sleep(150)
    wxState := "emoji"
    wxCol := 0, wxEmojiRow := 0
    p := WxCellPoint(r)
    WxMouseTo(p.x, p.y)
    ShowStatus("方向键选表情  OK 插入  ← 到头关闭")
}

WxConfirm() {
    global wxState
    r := WxRect()
    CoordMode("Mouse", "Screen")
    if wxState = "emoji" {
        Click()
        wxState := "normal"
        Sleep(100)
        ; 面板盖住了好友列表，插入后把鼠标移回聊天区，下一次 OK 才是发送。
        WxMouseToChat(r)
        ShowStatus("已插入表情  OK 发送")
        return
    }
    switch WxPane(r) {
        case "outside":
            ; 鼠标不在微信上时不点击也不发送，只把鼠标移到列表。
            WxHoverList(r)
            ShowStatus("好友列表：↑↓ 切换好友")
        case "list":
            ; 再次点击已打开的对话会把它关掉，所以这一行已经是绿色（已选中）时不点。
            MouseGetPos(, &my)
            CoordMode("Pixel", "Screen")
            color := PixelGetColor(r.x + WxScale(WX.listProbeX), my, "RGB")
            red := (color >> 16) & 0xFF, green := (color >> 8) & 0xFF, blue := color & 0xFF
            if !(green > red + 40 && green > blue + 40)
                Click()
            Sleep(350)
            ; 把光标放进输入框，鼠标回到聊天区。
            Click(r.x + (WxScale(WX.chatLeft) + r.w) // 2, r.y + r.h - WxScale(WX.composerBottom))
            WxMouseToChat(r)
            ShowStatus("对话：↑↓ 滑动  → 表情  OK 发送")
        case "chat":
            ; 先点输入框，确保回车发到这里。输入框为空时微信不会发送。
            Click(r.x + (WxScale(WX.chatLeft) + r.w) // 2, r.y + r.h - WxScale(WX.composerBottom))
            Sleep(80)
            Send("{Enter}")
            WxMouseToChat(r)
            ShowStatus("已发送")
    }
}

; ===== ChatGPT =====
; 三种状态：list 选对话（↑↓ 切换，OK 进入，不会发送）、chat 对话内（↑↓ 滑动记录，← 删字，→ 选模型，OK 发送）、
; model 推理强度面板（←→ 调节，OK 或设置键关闭）。快捷键来自应用自带命令，不依赖坐标。
global gptState := "list"

GptSetState(state, status) {
    global gptState := state
    SetTimer(GptModelExpired, state = "model" ? -20000 : 0)
    ShowStatus(status)
}

; 选择器可能已被鼠标或超时关闭，到时间就回到对话内，避免之后的按键还当作在选模型。
GptModelExpired() {
    global gptState
    if gptState = "model"
        gptState := "chat"
}

GptMouseToChat() {
    WinGetPos(&x, &y, &w, &h, TARGET)
    WxMouseTo(x + w * 60 // 100, y + h * 45 // 100)
}

GptMove(dx, dy) {
    switch gptState {
        case "list":
            if dy != 0
                Send(dy < 0 ? "^![" : "^!]")
        case "chat":
            if dy != 0 {
                GptMouseToChat()
                Sleep(60)
                Loop 3
                    WxWheel(dy < 0 ? "Up" : "Down")
            } else if dx < 0 {
                Send("{Backspace}")
            } else {
                Send("^+m")
                GptSetState("model", "推理强度：←→ 调节  OK 关闭")
            }
        case "model":
            ; 推理强度是滑块，应用规定用 ←→ 调节。只调强度，↑↓ 不发送，避免移到模型选项上。
            if dx != 0 {
                SetTimer(GptModelExpired, -20000)
                Send(dx < 0 ? "{Left}" : "{Right}")
            }
    }
}

GptConfirm() {
    switch gptState {
        case "list":
            GptMouseToChat()
            GptSetState("chat", "对话：↑↓ 滑动  ← 删字  → 模型  OK 发送")
        case "chat":
            Send("{Enter}")
            ShowStatus("已发送")
        case "model":
            ; 回车可能选中菜单里的模型项，这里只关闭面板。
            Send("{Esc}")
            GptSetState("chat", "已关闭强度选择")
    }
}

GptBack() {
    switch gptState {
        case "chat":
            GptSetState("list", "选对话：↑↓ 切换  OK 进入")
        case "model":
            Send("{Esc}")
            GptSetState("chat", "已关闭强度选择")
    }
}

GptNew() {
    Send("^n")
    GptSetState("chat", "新对话：输入后按 OK 发送")
}

; ===== Claude =====
; 逻辑和 ChatGPT 相同，快捷键来自 Claude 应用菜单：Ctrl+Tab / Ctrl+Shift+Tab 切换会话，Ctrl+N 新建。
; 应用没有调推理强度的快捷键，所以 → 空着。
global claudeState := "list"

ClaudeMouseToChat() {
    WinGetPos(&x, &y, &w, &h, "ahk_exe claude.exe")
    WxMouseTo(x + w * 60 // 100, y + h * 45 // 100)
}

ClaudeMove(dy) {
    if claudeState = "list" {
        Send(dy < 0 ? "^+{Tab}" : "^{Tab}")
    } else {
        ClaudeMouseToChat()
        Sleep(60)
        Loop 3
            WxWheel(dy < 0 ? "Up" : "Down")
    }
}

ClaudeDelete() {
    if claudeState = "chat"
        Send("{Backspace}")
}

ClaudeConfirm() {
    global claudeState
    if claudeState = "list" {
        claudeState := "chat"
        ClaudeMouseToChat()
        ShowStatus("对话：↑↓ 滑动  ← 删字  OK 发送")
    } else {
        Send("{Enter}")
        ShowStatus("已发送")
    }
}

ClaudeBack() {
    global claudeState := "list"
    ShowStatus("选对话：↑↓ 切换  OK 进入")
}

ClaudeNew() {
    global claudeState := "chat"
    Send("^n")
    ShowStatus("新对话：输入后按 OK 发送")
}

; ===== Grok Bot =====
; 操作逻辑和微信相同：鼠标在列表上时 ↑↓ 逐个切换对话，在聊天区时滑动聊天记录，OK 发送；→ 点语音聊天按钮。
; 坐标在 120 DPI 下实测。选中行是灰色 #E4E4E4，鼠标悬停也会变灰，所以先把鼠标移开再找选中行。
GROK := {win: "ahk_exe Grok Bot.exe", listX: 180, listTop: 258, listStep: 72.4, chatLeft: 350,
    probeX: 328, listBottom: 100, composerBottom: 47, voiceRight: 47, voiceBottom: 47}

GrokRect() {
    WinGetPos(&x, &y, &w, &h, GROK.win)
    return {x: x, y: y, w: w, h: h}
}

GrokHoverList(r) => WxMouseTo(r.x + WxScale(GROK.listX), r.y + WxScale(GROK.listTop))

GrokMouseToChat(r) => WxMouseTo(r.x + (WxScale(GROK.chatLeft) + r.w) // 2, r.y + r.h * 45 // 100)

GrokClickComposer(r) {
    CoordMode("Mouse", "Screen")
    Click(r.x + (WxScale(GROK.chatLeft) + r.w) // 2, r.y + r.h - WxScale(GROK.composerBottom))
}

GrokPane(r) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    if mx < r.x || mx >= r.x + r.w || my < r.y || my >= r.y + r.h
        return "outside"
    return mx < r.x + WxScale(GROK.chatLeft) ? "list" : "chat"
}

GrokMove(dx, dy) {
    r := GrokRect()
    if dx < 0 {
        GrokHoverList(r)
        ShowStatus("对话列表：↑↓ 切换对话")
    } else if dx > 0 {
        CoordMode("Mouse", "Screen")
        Click(r.x + r.w - WxScale(GROK.voiceRight), r.y + r.h - WxScale(GROK.voiceBottom))
        GrokMouseToChat(r)
        DebugLog("Grok：点击语音聊天")
        ShowStatus("已点语音聊天")
    } else if GrokPane(r) = "chat" {
        GrokMouseToChat(r)
        ; 鼠标刚移过来时应用还没更新悬停位置，马上滚动会被忽略。
        Sleep(60)
        Loop 3
            WxWheel(dy < 0 ? "Up" : "Down")
    } else {
        GrokStep(r, dy)
    }
}

GrokConfirm() {
    r := GrokRect()
    switch GrokPane(r) {
        case "outside":
            ; 鼠标不在窗口上时不点击也不发送，只把鼠标移到列表。
            GrokHoverList(r)
            ShowStatus("对话列表：↑↓ 切换对话")
        case "list":
            GrokClickComposer(r)
            GrokMouseToChat(r)
            ShowStatus("对话：↑↓ 滑动  → 语音  OK 发送")
        case "chat":
            GrokClickComposer(r)
            Sleep(80)
            Send("{Enter}")
            GrokMouseToChat(r)
            ShowStatus("已发送")
    }
}

; 连续多个采样点都是选中色才算选中行，避免把文字边缘的灰色当成选中行。
GrokSelectedRowY(r) {
    top := r.y + WxScale(GROK.listTop - 45)
    bottom := r.y + r.h - WxScale(GROK.listBottom) + WxScale(40)
    pixels := ReadColumn(r.x + WxScale(GROK.probeX), top, bottom)
    run := 0, first := 0, last := 0
    y := top
    while y < bottom {
        color := NumGet(pixels, (y - top) * 4, "uint")
        red :=(color >> 16) & 0xFF, green := (color >> 8) & 0xFF, blue := color & 0xFF
        if Abs(red - 0xE4) <= 4 && Abs(green - 0xE4) <= 4 && Abs(blue - 0xE4) <= 4 {
            first := run ? first : y
            last := y
            run++
        } else {
            if run >= 6
                break
            run := 0
        }
        y += WxScale(6)
    }
    return run >= 6 ? (first + last) // 2 : 0
}

GrokStep(r, dy) {
    listX := r.x + WxScale(GROK.listX)
    topLimit := r.y + WxScale(GROK.listTop - 25)
    bottomLimit := r.y + r.h - WxScale(GROK.listBottom)
    CoordMode("Mouse", "Screen")
    Loop 3 {
        GrokMouseToChat(r)
        Sleep(80)
        current := GrokSelectedRowY(r)
        if !current {
            GrokHoverList(r)
            Sleep(40)
            Click()
            return
        }
        target := current + dy * WxScale(GROK.listStep)
        if target >= topLimit && target <= bottomLimit {
            WxMouseTo(listX, target)
            Sleep(40)
            Click()
            return
        }
        WxMouseTo(listX, r.y + r.h // 2)
        Loop 2
            WxWheel(dy < 0 ? "Up" : "Down")
        Sleep(150)
    }
}

OpenSearch(k) {
    Send("^k")
    SetSearch(true)
}

Cancel(k) {
    SetSearch(false)
    Send("{Esc}")
}

OpenApp(k) {
    SetSearch(false)
    if WinExist(TARGET)
        BringToFront(TARGET)
    else
        Run(APP_ID)
}

RunParam(k) {
    ; Claude 的快捷方式指向 explorer.exe，从目标路径认不出程序，所以按名称找它的窗口。
    if k.param = "Claude" && WinExist("ahk_exe claude.exe") {
        BringToFront("ahk_exe claude.exe")
        return
    }
    apps := InstalledApps()
    if apps.Has(k.param) {
        target := ""
        try FileGetShortcut(apps[k.param], &target)
        ActivateOrRun(target, apps[k.param])
    } else
        ActivateOrRun(k.param, k.param)
}

SetMode(on) {
    global remoteMode, searchOpen, wxState, gptState, claudeState
    remoteMode := on
    searchOpen := false
    SetTimer(ClearSearch, 0)
    if on {
        wxState := "normal"
        ; ChatGPT 和 Claude 每次都从选对话开始，这时 OK 只是进入对话，不会发送。
        gptState := "list"
        claudeState := "list"
        typingWatch.Start()
        ShowStatus("遥控模式：开")
        Touch()
    } else {
        typingWatch.Stop()
        SetTimer(ExitIdle, 0)
        if !listening
            overlay.Hide()
    }
}

; 每次按键都刷新闲置计时；传入文字时在提示条上显示，方便区分“没收到”和“收到但应用反应慢”。
Touch(label := "") {
    if remoteMode
        SetTimer(ExitIdle, -IDLE_MS)
    if label != ""
        ShowStatus(label)
}
; 看视频时可能很久不按键，所以有专属按键的应用在前台时不因闲置退出。
ExitIdle() {
    if ActiveProfile()
        SetTimer(ExitIdle, -IDLE_MS)
    else
        SetMode(false)
}

ClearSearch() {
    global searchOpen := false
    if remoteMode
        ShowStatus("遥控模式：开")
}

ShowStatus(text) {
    overlayText.Value := text
    overlay.Show("NoActivate x" (A_ScreenWidth - 330) " y" (A_ScreenHeight - 100) " w300 h28")
    if StatusAutoHides()
        SetTimer(HideIfIdle, -1500)
}

; 有专属按键的应用在前台时提示条也自动消失，避免一直挡在视频上。
StatusAutoHides() => !listening && (!remoteMode || ActiveProfile())

HideIfIdle() {
    if StatusAutoHides()
        overlay.Hide()
}

SetSearch(on) {
    global searchOpen := on
    if on {
        SetTimer(ClearSearch, -SEARCH_MS)
        ShowStatus("搜索：↑↓ 选择  OK 打开")
    } else {
        SetTimer(ClearSearch, 0)
        if remoteMode
            ShowStatus("遥控模式：开")
    }
}

; ===== 设置窗口 =====

OpenSettings(*) {
    SetMode(false)
    ClosePicker()
    g := Gui(, "遥控器按键设置")
    g.SetFont("s10", "Microsoft YaHei UI")
    labels := ["应用列表（菜单键）", "遥控模式（中间键）"]
    for exe, profile in PROFILES
        labels.Push(profile.label)
    labels.Push("语音识别")
    tabs := g.Add("Tab3", "xm ym w680 h490", labels)
    tabs.UseTab(1)
    g.Add("Text", "Section w650", "按菜单键弹出这个列表，↑↓ 选择，OK 打开。从下拉框选应用后点“添加”，也可以手填路径或网址。")
    box := g.Add("ListBox", "xs y+10 w420 r16", appList)
    combo := g.Add("ComboBox", "x+12 yp w210", AppNames())
    add := g.Add("Button", "xp y+10 w210", "添加")
    add.OnEvent("Click", (*) => ListAdd(box, combo))
    up := g.Add("Button", "xp y+24 w210", "上移")
    up.OnEvent("Click", (*) => ListMove(box, -1))
    down := g.Add("Button", "xp y+8 w210", "下移")
    down.OnEvent("Click", (*) => ListMove(box, 1))
    del := g.Add("Button", "xp y+24 w210", "移除")
    del.OnEvent("Click", (*) => ListRemove(box))
    tabs.UseTab(2)
    g.Add("Text", "Section w650", "按中间键进入遥控模式后，这些键控制 ChatGPT。语音键不需要进入遥控模式。返回、主页、音量、静音没有传到电脑，无法设置。")
    rows := []
    for k in KEYS
        rows.Push(AddRow(g, k))
    tabIndex := 2
    for exe, profile in PROFILES {
        tabIndex++
        tabs.UseTab(tabIndex)
        g.Add("Text", "Section w650", "遥控模式下，" profile.label "在前台时使用这一页的功能。先按中间键进入遥控模式。")
        for entry in profile.entries
            rows.Push(AddRow(g, entry))
    }
    tabs.UseTab(tabIndex + 1)
    voice := AddVoiceTab(g)
    tabs.UseTab()
    save := g.Add("Button", "xm y510 w130 Default", "保存并生效")
    save.OnEvent("Click", (*) => SaveSettings(rows, box, voice))
    reset := g.Add("Button", "x+10 yp w130", "恢复默认")
    reset.OnEvent("Click", (*) => ResetSettings())
    g.Show()
}

AddVoiceTab(g) {
    g.Add("Text", "Section w650", "选云端服务后，语音会上传给该服务识别，按它的价格计费；结束说话后才出字。识别失败时自动改用本机离线识别。")
    g.Add("Text", "xs y+16 w90", "识别服务")
    provider := g.Add("DropDownList", "x+8 yp-3 w220", VOICE_ORDER)
    current := IniRead(CONFIG, "VoiceApi", "provider", VOICE_LOCAL)
    for i, name in VOICE_ORDER
        if name = current
            provider.Choose(i)
    if !provider.Value
        provider.Choose(1)
    g.Add("Text", "xs y+16 w90", "接口地址")
    base := g.Add("Edit", "x+8 yp-3 w540", IniRead(CONFIG, "VoiceApi", "baseUrl", ""))
    g.Add("Text", "xs y+16 w90", "模型")
    model := g.Add("Edit", "x+8 yp-3 w540", IniRead(CONFIG, "VoiceApi", "model", ""))
    g.Add("Text", "xs y+16 w90", "语言")
    language := g.Add("Edit", "x+8 yp-3 w120", IniRead(CONFIG, "VoiceApi", "language", "zh"))
    g.Add("Text", "x+10 yp+3 w400", "zh 为中文；留空则自动判断语言")
    g.Add("Text", "xs y+16 w90", "API Key")
    key := g.Add("Edit", "x+8 yp-3 w420 Password", "")
    remove := g.Add("Button", "x+8 yp w112", "删除已存 Key")
    status := g.Add("Text", "xs y+14 w650", KeyStatusText())
    remove.OnEvent("Click", (*) => RemoveVoiceKey(status))
    provider.OnEvent("Change", (*) => FillProvider(provider, base, model))
    return {provider: provider, url: base, model: model, language: language, key: key}
}

KeyStatusText() => FileExist(VOICE_KEY) ? "已保存 Key（已加密）。输入框留空表示继续使用它。" : "还没有保存 Key。Key 只填在这里，不要发到聊天里。"

RemoveVoiceKey(status) {
    if FileExist(VOICE_KEY)
        FileDelete(VOICE_KEY)
    status.Value := KeyStatusText()
}

FillProvider(provider, base, model) {
    if provider.Text = "自定义"
        return
    preset := VOICE_PROVIDERS[provider.Text]
    base.Value := preset.url
    model.Value := preset.model
}

; 返回错误提示，没有问题时返回空字符串。
CheckVoice(voice) {
    if voice.provider.Text = VOICE_LOCAL
        return ""
    url := Trim(voice.url.Value)
    if !(url ~= "i)^https://" || url ~= "i)^http://127\.0\.0\.1")
        return "接口地址必须以 https:// 开头，否则 Key 会被明文发送。"
    if Trim(voice.model.Value) = ""
        return "请填写模型名称。"
    if Trim(voice.key.Value) = "" && !FileExist(VOICE_KEY)
        return "请填写 API Key，或把识别服务改回“本机离线”。"
    return ""
}

ListItems(box) {
    items := []
    count := SendMessage(0x18B, 0, 0, box) ; LB_GETCOUNT
    Loop count {
        len := SendMessage(0x18A, A_Index - 1, 0, box) ; LB_GETTEXTLEN
        buf := Buffer((len + 1) * 2)
        SendMessage(0x189, A_Index - 1, buf.Ptr, box) ; LB_GETTEXT
        items.Push(StrGet(buf))
    }
    return items
}

ListAdd(box, combo) {
    item := Trim(combo.Text)
    if item != "" {
        box.Add([item])
        combo.Text := ""
    }
}

ListMove(box, step) {
    i := box.Value
    items := ListItems(box)
    j := i + step
    if !i || j < 1 || j > items.Length
        return
    temp := items[i], items[i] := items[j], items[j] := temp
    box.Delete()
    box.Add(items)
    box.Choose(j)
}

ListRemove(box) {
    if box.Value
        box.Delete(box.Value)
}

AddRow(g, k) {
    names := ACTION_ORDER.Clone()
    if k.id = "Voice"
        names.InsertAt(1, DICTATION)
    g.Add("Text", "xs y+10 w70", k.name)
    ddl := g.Add("DropDownList", "x+8 yp-3 w220", names)
    for i, n in names
        if n = k.action
            ddl.Choose(i)
    ed := g.Add("ComboBox", "x+8 yp w320", AppNames())
    ed.Text := k.param
    ddl.OnEvent("Change", SyncParam.Bind(ddl, ed))
    SyncParam(ddl, ed)
    return {key: k, ddl: ddl, ed: ed}
}

SyncParam(ddl, ed, *) {
    needs := ACTIONS.Has(ddl.Text) && ACTIONS[ddl.Text].param != ""
    ed.Enabled := needs
    if !needs
        ed.Text := ""
}

SaveSettings(rows, box, voice) {
    items := ListItems(box)
    if !items.Length {
        MsgBox("应用列表不能为空，至少留一个应用。", "遥控器按键设置")
        return
    }
    problem := CheckVoice(voice)
    if problem != "" {
        MsgBox(problem, "遥控器按键设置")
        return
    }
    IniWrite(voice.provider.Text, CONFIG, "VoiceApi", "provider")
    IniWrite(Trim(voice.url.Value), CONFIG, "VoiceApi", "baseUrl")
    IniWrite(Trim(voice.model.Value), CONFIG, "VoiceApi", "model")
    IniWrite(Trim(voice.language.Value), CONFIG, "VoiceApi", "language")
    if Trim(voice.key.Value) != ""
        SaveVoiceKey(Trim(voice.key.Value))
    for r in rows {
        if ACTIONS.Has(r.ddl.Text) && ACTIONS[r.ddl.Text].param != "" && Trim(r.ed.Text) = "" {
            MsgBox(r.key.name " 选了“" r.ddl.Text "”，右边的内容不能为空。", "遥控器按键设置")
            return
        }
    }
    for r in rows {
        IniWrite(r.ddl.Text, CONFIG, r.key.id, "action")
        IniWrite(Trim(r.ed.Text), CONFIG, r.key.id, "param")
    }
    try IniDelete(CONFIG, "AppList")
    IniWrite(items.Length, CONFIG, "AppList", "count")
    for i, item in items
        IniWrite(item, CONFIG, "AppList", "item" i)
    Restart("")
}

ResetSettings() {
    if FileExist(CONFIG)
        FileDelete(CONFIG)
    Restart("--settings")
}

; 新实例启动时由 #SingleInstance Force 替换当前实例，并重新注册所有按键。
Restart(arg) {
    Run('"' A_AhkPath '" "' A_ScriptFullPath '" ' arg)
    Sleep(3000)
    ExitApp()
}
