# cc-vscode-hud.ps1
# VS Code 視窗切換 + Claude Code 狀態浮窗(跟 cc-hud.ps1 同一套外觀,獨立工具、互不影響)
# 上半部:顯示 Claude Code 目前狀態(讀同一份 state\*.json)
# 下半部:列出目前開著的所有 VS Code 視窗,點一下就還原/切換過去
# 啟動: powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File cc-vscode-hud.ps1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

# 編譯成 .exe 之後 $PSScriptRoot 會是空的,退而用目前執行檔的實際路徑當作根目錄
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent }

# hooks-snippet.json 裡的 hook 命令固定指向 C:\Users\<you>\.claude\hud\cc-status.ps1,
# 所以狀態檔實際上都寫在那個資料夾底下 —— 不管這支 HUD 本身被複製/執行到哪裡,
# 都要讀同一個地方,不能用自己所在資料夾底下的 state(否則永遠讀不到 hook 寫的檔案)
$stateDir = Join-Path $env:USERPROFILE '.claude\hud\state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# 每一列最右邊的開啟圖示,先載入一次共用,避免每次畫列都重新讀檔
$openIconSource = $null
$openIconPath = Join-Path $ScriptRoot 'open.png'
if (Test-Path $openIconPath) {
    try {
        $openIconSource = New-Object System.Windows.Media.Imaging.BitmapImage
        $openIconSource.BeginInit()
        $openIconSource.UriSource = New-Object System.Uri($openIconPath, [System.UriKind]::Absolute)
        $openIconSource.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $openIconSource.EndInit()
        $openIconSource.Freeze()
    } catch { $openIconSource = $null }
}

# 標題列上的「新開一個 VS Code」圖示
$addIconSource = $null
$addIconPath = Join-Path $ScriptRoot 'add.png'
if (Test-Path $addIconPath) {
    try {
        $addIconSource = New-Object System.Windows.Media.Imaging.BitmapImage
        $addIconSource.BeginInit()
        $addIconSource.UriSource = New-Object System.Uri($addIconPath, [System.UriKind]::Absolute)
        $addIconSource.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $addIconSource.EndInit()
        $addIconSource.Freeze()
    } catch { $addIconSource = $null }
}

# 標題列上的「常用專案清單」圖示
$reduceIconSource = $null
$reduceIconPath = Join-Path $ScriptRoot 'reduce.png'
if (Test-Path $reduceIconPath) {
    try {
        $reduceIconSource = New-Object System.Windows.Media.Imaging.BitmapImage
        $reduceIconSource.BeginInit()
        $reduceIconSource.UriSource = New-Object System.Uri($reduceIconPath, [System.UriKind]::Absolute)
        $reduceIconSource.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $reduceIconSource.EndInit()
        $reduceIconSource.Freeze()
    } catch { $reduceIconSource = $null }
}

# 常用專案清單存檔位置
$favoritesPath = Join-Path $ScriptRoot 'favorites.json'

function Get-Favorites {
    if (-not (Test-Path $favoritesPath)) { return @() }
    try {
        $raw = @(Get-Content $favoritesPath -Raw -ErrorAction Stop | ConvertFrom-Json)
        return @($raw | ForEach-Object {
            [PSCustomObject]@{ Name = [string]$_.Name; Path = [string]$_.Path; Pinned = [bool]$_.Pinned }
        })
    } catch { return @() }
}

function Save-Favorites([array]$items) {
    try { @($items) | ConvertTo-Json -Depth 3 | Set-Content -Path $favoritesPath -Encoding UTF8 } catch { }
}

# VS Code 視窗標題通常只有資料夾名稱、沒有完整路徑,這裡去讀 VS Code 自己記錄的
# 「目前開著的視窗」清單反查完整路徑,好讓「加入常用專案」不用手動選一次。
# 舊版 VS Code 這份清單在 %APPDATA%\Code\storage.json 的 openedPathsList,
# 新版已經搬到 %APPDATA%\Code\User\globalStorage\storage.json 的 windowsState —
# 兩邊都是未公開格式,讀不到或格式對不上就直接放棄回傳 $null,不影響其他功能。
function Resolve-VsCodeFolderPath([string]$projectName) {
    if (-not $projectName) { return $null }
    $storagePath = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
    if (-not (Test-Path $storagePath)) { $storagePath = Join-Path $env:APPDATA 'Code\storage.json' }
    if (-not (Test-Path $storagePath)) { return $null }
    try {
        $storage = Get-Content $storagePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $uris = @()

        # 新版:windowsState 裡目前開著的每個視窗
        if ($storage.windowsState) {
            if ($storage.windowsState.openedWindows) {
                foreach ($w in $storage.windowsState.openedWindows) {
                    if ($w.folder) { $uris += [string]$w.folder }
                }
            }
            if ($storage.windowsState.lastActiveWindow -and $storage.windowsState.lastActiveWindow.folder) {
                $uris += [string]$storage.windowsState.lastActiveWindow.folder
            }
        }

        # 舊版:openedPathsList 的歷史紀錄
        if ($storage.openedPathsList -and $storage.openedPathsList.entries) {
            foreach ($e in $storage.openedPathsList.entries) {
                if ($e.folderUri) { $uris += [string]$e.folderUri }
                elseif ($e.workspace -and $e.workspace.configPath) { $uris += [string]$e.workspace.configPath }
            }
        }

        foreach ($uri in $uris) {
            try {
                # 先整段 unescape 再建 Uri 物件,[Uri] 才認得出 "file:///c:/..." 這種磁碟機代號寫法,
                # 不然碰到 VS Code 把冒號也編碼成 %3A 的情況,LocalPath 會退化成 "/c:/Users/..." 這種
                # 開頭多一個斜線、全部正斜線的畸形路徑(能比對到專案名稱,但拿去開資料夾會出問題)
                $decoded = [System.Uri]::UnescapeDataString($uri)
                $localPath = (New-Object System.Uri($decoded)).LocalPath
                if ($localPath -and (Split-Path $localPath -Leaf) -eq $projectName) { return $localPath }
            } catch { continue }
        }
    } catch { }
    return $null
}

# 互動式加入常用專案:已經知道路徑(來自 Claude Code state 或 storage.json 反查)就直接存,
# 不知道路徑的話跳資料夾選擇 —— 這樣不管哪一列都按得下去,不會因為抓不到路徑就沒得選
function Add-FavoriteInteractive {
    param(
        [string]$SuggestedName,
        [string]$KnownPath = $null
    )

    $path = $KnownPath
    if (-not $path) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = if ($SuggestedName) { "找不到「$SuggestedName」的完整路徑,請手動選擇它的資料夾" } else { '選擇要加入常用清單的專案資料夾' }
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
        $path = $dlg.SelectedPath
    }

    $current = @(Get-Favorites)
    if ($current | Where-Object { $_.Path -eq $path }) {
        [System.Windows.MessageBox]::Show('這個路徑已經在常用清單裡了。', '常用專案', 'OK', 'Information') | Out-Null
        return $false
    }

    $defaultName = if ($SuggestedName) { $SuggestedName } else { Split-Path $path -Leaf }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('專案顯示名稱', '新增常用專案', $defaultName)
    if (-not $name) { $name = $defaultName }

    $current += [PSCustomObject]@{ Name = $name; Path = $path; Pinned = $false }
    Save-Favorites $current
    return $true
}

# 開一個 VS Code 視窗:有給路徑就開那個資料夾(已開著就切換過去),不然就是全新空視窗
function Open-VsCode([string]$path) {
    $argStr = if ($path) { '"{0}"' -f $path } else { '-n' }
    try {
        Start-Process -FilePath 'code' -ArgumentList $argStr -WindowStyle Hidden
    } catch {
        try { Start-Process -FilePath 'cmd.exe' -ArgumentList "/c code $argStr" -WindowStyle Hidden } catch { }
    }
}

# Win32 API:列舉、還原、置前視窗
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class VsWindowInfo {
    public IntPtr Handle;
    public string Title;
    public bool Minimized;
}

public class VsWin32 {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);

    // 列出所有標題含 "Visual Studio Code" 的可見視窗(一般版、Insiders 都吃得到)
    public static List<VsWindowInfo> FindWindows() {
        var result = new List<VsWindowInfo>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
            if (IsWindowVisible(hWnd)) {
                int len = GetWindowTextLength(hWnd);
                if (len > 0) {
                    var sb = new StringBuilder(len + 1);
                    GetWindowText(hWnd, sb, sb.Capacity);
                    string title = sb.ToString();
                    if (title.Contains("Visual Studio Code")) {
                        var info = new VsWindowInfo();
                        info.Handle = hWnd;
                        info.Title = title;
                        info.Minimized = IsIconic(hWnd);
                        result.Add(info);
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // 還原(如果被縮小)並切換過去最上層
    public static void Activate(IntPtr hWnd) {
        ShowWindow(hWnd, 9); // SW_RESTORE
        SetForegroundWindow(hWnd);
    }

    // 依視窗標題完全比對(拿來判斷這支程式自己是不是已經開了一個視窗)
    public static IntPtr FindByExactTitle(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
            int len = GetWindowTextLength(hWnd);
            if (len > 0) {
                var sb = new StringBuilder(len + 1);
                GetWindowText(hWnd, sb, sb.Capacity);
                if (sb.ToString() == title) { found = hWnd; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

# 單一實例:已經有一個在跑的話,把它叫到最前面就好,不要再開新視窗
$createdNew = $false
$appMutex = New-Object System.Threading.Mutex($true, 'Global\VSCodeHUD_SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    $existing = [VsWin32]::FindByExactTitle('VS Code HUD')
    if ($existing -ne [IntPtr]::Zero) { [VsWin32]::Activate($existing) }
    exit
}

# 安全網:任何沒接住的例外都不要讓整個視窗當掉消失,吃掉繼續跑就好
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
    param($senderObj, $e)
    $e.Handled = $true
})

[xml]$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VS Code HUD"
        Width="320" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Left="370" Top="40">
  <Border CornerRadius="10" Background="#FF1B1B26"
          BorderBrush="#FF34344A" BorderThickness="1" Padding="12,10,12,12">
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
          <ColumnDefinition Width="Auto" />
          <ColumnDefinition Width="Auto" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <TextBlock Name="Header" Grid.Column="0" Text="VS CODE"
                   Foreground="#FF7A7A96" FontFamily="Consolas"
                   FontSize="9" FontWeight="Bold" VerticalAlignment="Center" />
        <Image Name="FavButton" Grid.Column="1" Width="14" Height="14"
               Cursor="Hand" Opacity="0.75" ToolTip="常用 VS Code 專案"
               Margin="10,0,0,0" VerticalAlignment="Center" />
        <TextBlock Name="RefreshButton" Grid.Column="2" Text="&#8635;"
                   Foreground="#FF7A7A96" FontFamily="Consolas"
                   FontSize="12" FontWeight="Bold" Cursor="Hand"
                   ToolTip="立即重新整理狀態"
                   Margin="10,0,0,0" VerticalAlignment="Center" />
        <Image Name="AddButton" Grid.Column="3" Width="14" Height="14"
               Cursor="Hand" Opacity="0.75" ToolTip="開新的 VS Code 視窗"
               Margin="10,0,0,0" VerticalAlignment="Center" />
        <TextBlock Name="CloseButton" Grid.Column="4" Text="&#10005;"
                   Foreground="#FF7A7A96" FontFamily="Consolas"
                   FontSize="11" FontWeight="Bold" Cursor="Hand"
                   Padding="10,0,0,0" VerticalAlignment="Center" />
      </Grid>
      <StackPanel Name="List" />
    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xamlText
$win = [Windows.Markup.XamlReader]::Load($reader)
$list = $win.FindName('List')
$closeButton = $win.FindName('CloseButton')
$addButton = $win.FindName('AddButton')
$refreshButton = $win.FindName('RefreshButton')
$favButton = $win.FindName('FavButton')
if ($addIconSource) { $addButton.Source = $addIconSource }
if ($reduceIconSource) { $favButton.Source = $reduceIconSource }

$conv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$hex) { return $conv.ConvertFromString($hex) }

# 每種狀態的圖示、顏色、標籤(跟 cc-hud.ps1 同一份規則)
function Get-Look([string]$state) {
    switch ($state) {
        'unknown' { return @{ Icon = '[?]'; Color = '#FF6C6C86'; Label = '狀態未知' } }
        'stopped' { return @{ Icon = '[-]'; Color = '#FF6C6C86'; Label = '已中止' } }
        'waiting' { return @{ Icon = '[!]'; Color = '#FFFFC46B'; Label = '等你回覆' } }
        'done'    { return @{ Icon = '[v]'; Color = '#FF7FD99A'; Label = '完成'     } }
        'running' { return @{ Icon = '[>]'; Color = '#FF7FB0F2'; Label = '執行中'   } }
        'thinking'{ return @{ Icon = '[~]'; Color = '#FFB79BF2'; Label = '思考中'   } }
        default   { return @{ Icon = '[?]'; Color = '#FF6C6C86'; Label = $state     } }
    }
}

# Bootstrap Icons(MIT 授權)的 star / star-fill 向量路徑,直接畫成 Path,不用額外包字型檔
$starOutlineData = 'M2.866 14.85c-.078.444.36.791.746.593l4.39-2.256 4.389 2.256c.386.198.824-.149.746-.592l-.83-4.73 3.522-3.356c.33-.314.16-.888-.282-.95l-4.898-.696L8.465.792a.513.513 0 0 0-.927 0L5.354 5.12l-4.898.696c-.441.062-.612.636-.283.95l3.523 3.356-.83 4.73zm4.905-2.767-3.686 1.894.694-3.957a.56.56 0 0 0-.163-.505L1.71 6.745l4.052-.576a.53.53 0 0 0 .393-.288L8 2.223l1.847 3.658a.53.53 0 0 0 .393.288l4.052.575-2.906 2.77a.56.56 0 0 0-.163.506l.694 3.957-3.686-1.894a.5.5 0 0 0-.461 0z'
$starFillData = 'M3.612 15.443c-.386.198-.824-.149-.746-.592l.83-4.73L.173 6.765c-.329-.314-.158-.888.283-.95l4.898-.696L7.538.792c.197-.39.73-.39.927 0l2.184 4.327 4.898.696c.441.062.612.636.282.95l-3.522 3.356.83 4.73c.078.443-.36.79-.746.592L8 13.187l-4.389 2.256z'

function New-StarIcon {
    param(
        [bool]$Filled = $false,
        [string]$Color = '#FF5C5C74',
        [double]$Size = 13
    )
    $p = New-Object Windows.Shapes.Path
    $p.Data = [Windows.Media.Geometry]::Parse($(if ($Filled) { $starFillData } else { $starOutlineData }))
    $p.Fill = Get-Brush $Color
    $p.Width = $Size
    $p.Height = $Size
    $p.Stretch = 'Uniform'
    return $p
}

function New-Column([string]$width) {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = if ($width -eq '*') {
        New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    } else {
        [System.Windows.GridLength]::Auto
    }
    return $cd
}

# 卡片式一列:VS Code 縮圖圖示 + 標題/副標 + 狀態圓點與標籤 + 箭頭 + 最右邊的開啟圖示
function Add-Row {
    param(
        [string]$Title,
        [string]$Sub,
        [string]$StatusLabel = '',
        [string]$StatusColor = '#FF6C6C86',
        [scriptblock]$OnClick = $null,
        [string]$FavPath = $null
    )

    $card = New-Object Windows.Controls.Border
    $card.CornerRadius = 8
    $card.Background = Get-Brush '#FF24242F'
    $card.Margin = '0,6,0,0'
    $card.Padding = '10,8,10,8'
    if ($OnClick) { $card.Cursor = [System.Windows.Input.Cursors]::Hand }

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in @('Auto', '*', 'Auto', 'Auto', 'Auto', 'Auto')) {
        $grid.ColumnDefinitions.Add((New-Column $w)) | Out-Null
    }

    # 0: VS Code 圖示(藍底圓角方塊)
    $iconBox = New-Object Windows.Controls.Border
    $iconBox.Width = 28
    $iconBox.Height = 28
    $iconBox.CornerRadius = 6
    $iconBox.Background = Get-Brush '#FF0C7ED9'
    $iconBox.VerticalAlignment = 'Center'
    $iconTxt = New-Object Windows.Controls.TextBlock
    $iconTxt.Text = [char]0x2039 + [char]0x002F + [char]0x203A
    $iconTxt.Foreground = Get-Brush '#FFFFFFFF'
    $iconTxt.FontFamily = 'Consolas'
    $iconTxt.FontSize = 10
    $iconTxt.FontWeight = 'Bold'
    $iconTxt.HorizontalAlignment = 'Center'
    $iconTxt.VerticalAlignment = 'Center'
    $iconBox.Child = $iconTxt
    [Windows.Controls.Grid]::SetColumn($iconBox, 0)
    $grid.Children.Add($iconBox) | Out-Null

    # 1: 標題 + 副標(時間 · 說明)
    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '10,0,8,0'
    $stack.VerticalAlignment = 'Center'
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = $Title
    $t1.Foreground = Get-Brush '#FFE8E8F0'
    $t1.FontFamily = 'Consolas'
    $t1.FontSize = 13
    $t1.FontWeight = 'Bold'
    $t1.TextTrimming = 'CharacterEllipsis'
    $stack.Children.Add($t1) | Out-Null

    if ($Sub) {
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = $Sub
        $t2.Foreground = Get-Brush '#FF8A8AA6'
        $t2.FontFamily = 'Consolas'
        $t2.FontSize = 10
        $t2.Margin = '0,2,0,0'
        $t2.TextTrimming = 'CharacterEllipsis'
        $stack.Children.Add($t2) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($stack, 1)
    $grid.Children.Add($stack) | Out-Null

    # 2: 狀態圓點 + 標籤
    if ($StatusLabel) {
        $statusPanel = New-Object Windows.Controls.StackPanel
        $statusPanel.Orientation = 'Horizontal'
        $statusPanel.VerticalAlignment = 'Center'
        $statusPanel.Margin = '0,0,8,0'

        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 7
        $dot.Height = 7
        $dot.Fill = Get-Brush $StatusColor
        $dot.VerticalAlignment = 'Center'
        $dot.Margin = '0,0,5,0'
        $statusPanel.Children.Add($dot) | Out-Null

        $statusTxt = New-Object Windows.Controls.TextBlock
        $statusTxt.Text = $StatusLabel
        $statusTxt.Foreground = Get-Brush $StatusColor
        $statusTxt.FontFamily = 'Consolas'
        $statusTxt.FontSize = 11
        $statusTxt.FontWeight = 'Bold'
        $statusTxt.VerticalAlignment = 'Center'
        $statusPanel.Children.Add($statusTxt) | Out-Null

        [Windows.Controls.Grid]::SetColumn($statusPanel, 2)
        $grid.Children.Add($statusPanel) | Out-Null
    }

    # 3: 箭頭
    if ($OnClick) {
        $chevron = New-Object Windows.Controls.TextBlock
        $chevron.Text = '>'
        $chevron.Foreground = Get-Brush '#FF5C5C74'
        $chevron.FontFamily = 'Consolas'
        $chevron.FontSize = 13
        $chevron.VerticalAlignment = 'Center'
        $chevron.Margin = '0,0,8,0'
        [Windows.Controls.Grid]::SetColumn($chevron, 3)
        $grid.Children.Add($chevron) | Out-Null
    }

    # 4: 加入常用專案(Bootstrap Icons 的星星)。每一列都會顯示 —— 抓得到路徑就直接加入,
    # 抓不到的話點下去會跳資料夾選擇,所以不會有某些列「按不下去」的狀況
    if ($OnClick) {
        $alreadyFav = $FavPath -and (@(Get-Favorites) | Where-Object { $_.Path -eq $FavPath })
        $favIcon = New-StarIcon -Filled:([bool]$alreadyFav) -Color $(if ($alreadyFav) { '#FFFFC46B' } else { '#FF5C5C74' })
        $favIcon.IsHitTestVisible = $false

        # 星星是一個實心很少的向量圖形,直接把 MouseLeftButtonDown 掛在 Path 上的話,
        # 點在星星「凹進去」的空白處會直接穿透到底下的卡片,變成觸發開啟該列 —— 所以
        # 外面包一層透明背景的 Border 撐滿整個可點擊區塊,事件也改掛在這層上面
        $favBtn = New-Object Windows.Controls.Border
        $favBtn.Width = 24
        $favBtn.Height = 24
        $favBtn.Background = Get-Brush 'Transparent'
        $favBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $favBtn.VerticalAlignment = 'Center'
        $favBtn.HorizontalAlignment = 'Center'
        $favBtn.Margin = '0,0,10,0'
        $favBtn.ToolTip = if ($alreadyFav) { '已加入常用專案' } else { '加入常用專案' }
        $favBtn.Child = $favIcon
        $favBtn.Add_MouseLeftButtonDown({
            param($srcObj, $evt)
            try {
                $evt.Handled = $true
                if (Add-FavoriteInteractive $Title $FavPath) { Update-Hud }
            } catch { }
        }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($favBtn, 4)
        $grid.Children.Add($favBtn) | Out-Null
    }

    # 5: 最右邊的開啟圖示(open.png),點下去跟點整列一樣會切換/還原過去該視窗
    if ($OnClick) {
        $openIcon = New-Object Windows.Controls.Image
        $openIcon.Width = 16
        $openIcon.Height = 16
        $openIcon.Margin = '2,0,0,0'
        $openIcon.VerticalAlignment = 'Center'
        $openIcon.Cursor = [System.Windows.Input.Cursors]::Hand
        $openIcon.ToolTip = '開啟'
        $openIcon.Opacity = 0.7
        if ($openIconSource) { $openIcon.Source = $openIconSource }
        $openIcon.Add_MouseEnter({ $openIcon.Opacity = 1.0 }.GetNewClosure())
        $openIcon.Add_MouseLeave({ $openIcon.Opacity = 0.7 }.GetNewClosure())
        $openIcon.Add_MouseLeftButtonDown({
            param($srcObj, $evt)
            try {
                $evt.Handled = $true
                & $OnClick
            } catch { }
        }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($openIcon, 5)
        $grid.Children.Add($openIcon) | Out-Null
    }

    $card.Child = $grid

    # 有給 OnClick 才會攔截點擊(標記 Handled),不然點下去會變成拖曳視窗
    if ($OnClick) {
        $card.Add_MouseLeftButtonDown({
            param($srcObj, $evt)
            try {
                $evt.Handled = $true
                & $OnClick
            } catch { }
        }.GetNewClosure())
    }

    $list.Children.Add($card) | Out-Null
}

# 重繪整個清單:定時器跟「立即重新整理」按鈕共用同一份邏輯
function Get-CodexStatusEntries {
    param([string]$SessionsPath = $(if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'sessions' } else { Join-Path $env:USERPROFILE '.codex\sessions' }))
    $now = Get-Date
    if ($script:codexNextScan -and $now -lt $script:codexNextScan) { return $script:codexEntries }
    $script:codexNextScan = $now.AddSeconds(3)
    if (-not $script:codexFileCache) { $script:codexFileCache = @{} }
    $entries = @()
    # Only recent sessions; cache parsed results and bound reads of long conversations.
    $files = @(Get-ChildItem -LiteralPath $SessionsPath -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $now.AddHours(-2) } | Sort-Object LastWriteTime -Descending)
    $livePaths = @{}
    foreach ($file in $files) {
        $livePaths[$file.FullName] = $true
        $stamp = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
        $cached = $script:codexFileCache[$file.FullName]
        if (-not $cached -or $cached.Stamp -ne $stamp) {
            $stream = $null; $reader = $null
            try {
                $stream = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite, Delete')
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                $meta = $reader.ReadLine() | ConvertFrom-Json -ErrorAction Stop
                if ($meta.type -ne 'session_meta' -or -not $meta.payload.cwd) { continue }
                # Subagents have their own logs and must not replace the parent status.
                if ($meta.payload.source -isnot [string]) { continue }
                $reader.DiscardBufferedData()
                $offset = [Math]::Max(0, $stream.Length - 262144)
                [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                if ($offset -gt 0) { [void]$reader.ReadLine() }
                $lines = $reader.ReadToEnd() -split "`n"
                $state = 'unknown'; $detail = ''; $ts = $file.LastWriteTime
                for ($i = $lines.Count - 2; $i -ge 0; $i--) {
                    try { $event = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    $p = $event.payload
                    if ($event.type -eq 'event_msg') {
                        switch ($p.type) {
                            'task_complete' { $state = 'done' }
                            'turn_aborted' { $state = 'stopped' }
                            'task_started' { $state = 'thinking' }
                            'user_message' { $state = 'thinking' }
                        }
                    } elseif ($event.type -eq 'response_item') {
                        if ($p.type -in @('function_call', 'custom_tool_call')) {
                            $state = 'running'; $detail = [string]$p.name
                            if ($p.name -match '(^|__)(request_user_input|request_user_input_async)$') { $state = 'waiting' }
                        } elseif ($p.type -eq 'message' -and $p.role -eq 'assistant' -and $p.phase -eq 'final') {
                            $state = 'done'
                        }
                    }
                    if ($state -ne 'unknown') {
                        try { $ts = ([datetimeoffset]$event.timestamp).LocalDateTime } catch { }
                        break
                    }
                }
                $entry = @{ Provider = 'Codex'; State = $state; Detail = $detail; Ts = $ts; Cwd = [string]$meta.payload.cwd }
                $cached = @{ Stamp = $stamp; Entry = $entry }
                $script:codexFileCache[$file.FullName] = $cached
            } catch { continue }
            finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
        }
        if ($cached -and ($now - $cached.Entry.Ts).TotalHours -lt 2) {
            $entry = $cached.Entry.Clone()
            if ($entry.State -in @('running', 'thinking') -and ($now - $file.LastWriteTime).TotalMinutes -gt 10) {
                $entry.State = 'unknown'; $entry.Detail = '近期無更新'
            }
            $entries += $entry
        }
    }
    foreach ($key in @($script:codexFileCache.Keys)) {
        if (-not $livePaths.ContainsKey($key)) { $script:codexFileCache.Remove($key) }
    }
    $script:codexEntries = @($entries | Sort-Object { $_.Ts } -Descending)
    return $script:codexEntries
}

function Update-Hud {
    # 整個更新包一層 try/catch,單次畫面更新失敗頂多這一輪不動,不會讓視窗整個當掉消失
    try {
    $list.Children.Clear()
    $now = Get-Date

    # ---- 先讀 Claude Code state,依專案名稱建索引,等一下貼到對應的 VS Code 視窗上 ----
    $statusByProject = @{}
    $statusEntries = @()
    $files = @(Get-ChildItem -Path $stateDir -Filter '*.json' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)

    foreach ($f in $files) {
        $s = $null
        try { $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if (-not $s -or -not $s.project) { continue }

        $ts = $now
        try { $ts = [datetime]$s.ts } catch { }
        if (($now - $ts).TotalHours -gt 2) { continue }

        $entry = @{ Provider = 'Claude'; State = [string]$s.state; Detail = [string]$s.detail; Ts = $ts; Cwd = [string]$s.cwd }
        $statusEntries += $entry

        # 同專案有多個 session 時,保留最新的那筆(檔案已依時間新到舊排序)
        if (-not $statusByProject.ContainsKey($s.project)) {
            $statusByProject[$s.project] = $entry
        }
    }

    $codexEntries = @(Get-CodexStatusEntries)
    # ---- VS Code 視窗清單與兩種助理的狀態 ----
    $vsWindows = $null
    try { $vsWindows = [VsWin32]::FindWindows() } catch { }

    if ($vsWindows -and $vsWindows.Count -gt 0) {
        foreach ($w in $vsWindows) {
            $trimmed = $w.Title -replace '\s*[-–—]\s*Visual Studio Code.*$', ''
            if (-not $trimmed) { $trimmed = 'Visual Studio Code' }
            $parts = $trimmed -split '\s+[-–—]\s+'
            $projectName = $parts[-1]

            $handle = $w.Handle
            $onClick = { [VsWin32]::Activate($handle) }.GetNewClosure()

            $info = $null
            if ($statusByProject.ContainsKey($projectName)) {
                $info = $statusByProject[$projectName]
            }
            else {
                # VS Code 開的是上層資料夾,但 Claude Code 在子資料夾(例如 FdaHealth\frontend)
                # 裡跑,視窗標題只有上層名稱比不到 —— 退而用 cwd 路徑片段回頭比對
                foreach ($entry in $statusEntries) {
                    if ($entry.Cwd -and ($entry.Cwd -match "(?i)[\\/]$([regex]::Escape($projectName))(?:[\\/]|$)")) {
                        $info = $entry
                        break
                    }
                }
            }

            # 完整路徑:有 Claude Code state 就直接用 cwd,不然試著從 VS Code 自己的
            # 最近開啟清單反查 —— 兩邊都拿不到就不顯示「加入常用專案」圖示
            $favPath = if ($info -and $info.Cwd) { $info.Cwd } else { Resolve-VsCodeFolderPath $projectName }

            $windowPath = Resolve-VsCodeFolderPath $projectName
            $codex = $codexEntries | Where-Object {
                if ($windowPath) {
                    $root = $windowPath.TrimEnd('\', '/') -replace '/', '\'
                    $cwd = $_.Cwd.TrimEnd('\', '/') -replace '/', '\'
                    $cwd -eq $root -or $cwd.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
                } else {
                    $_.Cwd -match "(?i)[\\/]$([regex]::Escape($projectName))(?:[\\/]|$)"
                }
            } | Select-Object -First 1
            if ($info) {
                $look = Get-Look $info.State
                $time = $info.Ts.ToString('HH:mm:ss')
                $sub = "Claude  $time"
                if ($info.Detail) { $sub += "  $([char]0xB7)  $($info.Detail)" }

                Add-Row $projectName $sub $look.Label $look.Color $onClick $favPath
            }
            elseif (-not $codex -and $w.Minimized) {
                Add-Row $projectName '已縮小,點一下還原' '已縮小' '#FF6C6C86' $onClick $favPath
            }
            elseif (-not $codex) {
                Add-Row $projectName '點一下切換過去' '' '#FF6C6C86' $onClick $favPath
            }

            if ($codex) {
                $look = Get-Look $codex.State
                $sub = 'Codex  ' + $codex.Ts.ToString('HH:mm:ss')
                if ($codex.Detail) { $sub += "  $([char]0xB7)  $($codex.Detail)" }
                Add-Row $projectName $sub $look.Label $look.Color $onClick $codex.Cwd
            }
        }
    }
    else {
        Add-Row '沒有偵測到 VS Code 視窗' '' '' '#FF5C5C74' $null
    }
    } catch { }
}

# 常用 VS Code 專案清單彈窗:搜尋 / 新增 / 釘選 / 重新命名 / 刪除 / 開啟
$script:favWin = $null
function Show-FavoritesWindow {
    if ($script:favWin -and $script:favWin.IsVisible) {
        try { $script:favWin.Activate() } catch { }
        return
    }

    [xml]$favXamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="常用 VS Code 專案"
        Width="440" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner">
  <Border CornerRadius="14" Background="#FF14141C"
          BorderBrush="#FF34344A" BorderThickness="1" Padding="20">
    <StackPanel>
      <Grid Name="FavHeaderGrid">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto" />
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Width="40" Height="40" CornerRadius="10" Background="#FF0C7ED9" VerticalAlignment="Center">
          <TextBlock Text="&#8249;/&#8250;" Foreground="White" FontFamily="Consolas" FontSize="13" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center" />
        </Border>
        <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
          <TextBlock Text="常用 VS Code 專案" Foreground="#FFE8E8F0" FontFamily="Consolas" FontSize="15" FontWeight="Bold" />
          <TextBlock Text="快速選擇、管理與新增常用專案" Foreground="#FF7A7A96" FontFamily="Consolas" FontSize="9" Margin="0,3,0,0" />
        </StackPanel>
        <TextBlock Name="CloseFavButton" Grid.Column="2" Text="&#10005;"
                   Foreground="#FF7A7A96" FontFamily="Consolas" FontSize="12" FontWeight="Bold"
                   Cursor="Hand" VerticalAlignment="Top" />
      </Grid>

      <Grid Margin="0,16,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" CornerRadius="8" Background="#FF1F1F2B"
                BorderBrush="#FF34344A" BorderThickness="1" Padding="10,0" Margin="0,0,10,0">
          <Grid>
            <TextBlock Name="SearchHint" Text="搜尋專案名稱或路徑" Foreground="#FF5C5C74"
                       FontFamily="Consolas" FontSize="11" VerticalAlignment="Center" IsHitTestVisible="False" />
            <TextBox Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="#FFE8E8F0"
                     CaretBrush="#FFE8E8F0" FontFamily="Consolas" FontSize="11" VerticalAlignment="Center"
                     VerticalContentAlignment="Center" Height="30" />
          </Grid>
        </Border>
        <Border Name="AddFavButton" Grid.Column="1" CornerRadius="8" Background="#FF0C7ED9"
                Padding="14,7" Cursor="Hand">
          <TextBlock Text="&#65291; 新增常用專案" Foreground="White" FontFamily="Consolas" FontSize="11" FontWeight="Bold" />
        </Border>
      </Grid>

      <ScrollViewer Margin="0,12,0,0" MaxHeight="340" VerticalScrollBarVisibility="Auto">
        <StackPanel Name="FavList" />
      </ScrollViewer>

      <Grid Margin="0,14,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="選擇專案後,將會直接在 VS Code 中開啟或切換至該工作區。"
                   Foreground="#FF5C5C74" FontFamily="Consolas" FontSize="9" TextWrapping="Wrap" />
        <TextBlock Name="CountText" Grid.Column="1" Text="" Foreground="#FF5C5C74"
                   FontFamily="Consolas" FontSize="9" Margin="10,0,0,0" VerticalAlignment="Top" />
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

    $favReader = New-Object System.Xml.XmlNodeReader $favXamlText
    $favWin = [Windows.Markup.XamlReader]::Load($favReader)
    $favWin.Owner = $win
    $script:favWin = $favWin

    $favHeaderGrid = $favWin.FindName('FavHeaderGrid')
    $closeFavButton = $favWin.FindName('CloseFavButton')
    $searchBox = $favWin.FindName('SearchBox')
    $searchHint = $favWin.FindName('SearchHint')
    $addFavButton = $favWin.FindName('AddFavButton')
    $favList = $favWin.FindName('FavList')
    $countText = $favWin.FindName('CountText')

    $favorites = New-Object System.Collections.ArrayList
    foreach ($item in (Get-Favorites)) { $favorites.Add($item) | Out-Null }

    function Persist-Favorites { Save-Favorites @($favorites) }

    # 一列常用專案:資料夾圖示 + 名稱/路徑 + 釘選/重新命名/刪除 + 開啟按鈕
    function Add-FavRow {
        param($Fav)

        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 8
        $card.Background = Get-Brush '#FF1C1C27'
        $card.Margin = '0,0,0,8'
        $card.Padding = '10,8,10,8'
        $card.Cursor = [System.Windows.Input.Cursors]::Hand

        $grid = New-Object Windows.Controls.Grid
        foreach ($w in @('Auto', '*', 'Auto', 'Auto')) {
            $grid.ColumnDefinitions.Add((New-Column $w)) | Out-Null
        }

        # 0: 資料夾圖示
        $iconBox = New-Object Windows.Controls.Border
        $iconBox.Width = 30
        $iconBox.Height = 30
        $iconBox.CornerRadius = 7
        $iconBox.Background = Get-Brush '#FF262633'
        $iconBox.VerticalAlignment = 'Center'
        $iconTxt = New-Object Windows.Controls.TextBlock
        $iconTxt.Text = [string][char]0xE8B7
        $iconTxt.FontFamily = 'Segoe MDL2 Assets'
        $iconTxt.FontSize = 14
        $iconTxt.Foreground = Get-Brush '#FF9AA0C0'
        $iconTxt.HorizontalAlignment = 'Center'
        $iconTxt.VerticalAlignment = 'Center'
        $iconBox.Child = $iconTxt
        [Windows.Controls.Grid]::SetColumn($iconBox, 0)
        $grid.Children.Add($iconBox) | Out-Null

        # 1: 名稱 + 路徑
        $stack = New-Object Windows.Controls.StackPanel
        $stack.Margin = '10,0,8,0'
        $stack.VerticalAlignment = 'Center'
        $t1 = New-Object Windows.Controls.TextBlock
        $t1.Text = $Fav.Name
        $t1.Foreground = Get-Brush '#FFE8E8F0'
        $t1.FontFamily = 'Consolas'
        $t1.FontSize = 13
        $t1.FontWeight = 'Bold'
        $t1.TextTrimming = 'CharacterEllipsis'
        $stack.Children.Add($t1) | Out-Null
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = $Fav.Path
        $t2.Foreground = Get-Brush '#FF7A7A96'
        $t2.FontFamily = 'Consolas'
        $t2.FontSize = 10
        $t2.Margin = '0,2,0,0'
        $t2.TextTrimming = 'CharacterEllipsis'
        $stack.Children.Add($t2) | Out-Null
        [Windows.Controls.Grid]::SetColumn($stack, 1)
        $grid.Children.Add($stack) | Out-Null

        # 2: 釘選 / 重新命名 / 刪除
        $actions = New-Object Windows.Controls.StackPanel
        $actions.Orientation = 'Horizontal'
        $actions.VerticalAlignment = 'Center'
        $actions.Margin = '0,0,10,0'

        $pinTxt = New-Object Windows.Controls.TextBlock
        $pinTxt.Text = [string][char]0xE718
        $pinTxt.FontFamily = 'Segoe MDL2 Assets'
        $pinTxt.FontSize = 13
        $pinTxt.Foreground = if ($Fav.Pinned) { Get-Brush '#FF7FB0F2' } else { Get-Brush '#FF6C6C86' }
        $pinTxt.Cursor = [System.Windows.Input.Cursors]::Hand
        $pinTxt.ToolTip = '釘選在最上面'
        $pinTxt.Margin = '0,0,10,0'
        $pinTxt.Add_MouseLeftButtonDown({
            param($s2, $e2)
            try {
                $e2.Handled = $true
                $Fav.Pinned = -not $Fav.Pinned
                Persist-Favorites
                Render-Favorites -Filter $searchBox.Text
            } catch { }
        }.GetNewClosure())
        $actions.Children.Add($pinTxt) | Out-Null

        $editTxt = New-Object Windows.Controls.TextBlock
        $editTxt.Text = [string][char]0xE70F
        $editTxt.FontFamily = 'Segoe MDL2 Assets'
        $editTxt.FontSize = 13
        $editTxt.Foreground = Get-Brush '#FF6C6C86'
        $editTxt.Cursor = [System.Windows.Input.Cursors]::Hand
        $editTxt.ToolTip = '重新命名'
        $editTxt.Margin = '0,0,10,0'
        $editTxt.Add_MouseLeftButtonDown({
            param($s2, $e2)
            try {
                $e2.Handled = $true
                $newName = [Microsoft.VisualBasic.Interaction]::InputBox('專案顯示名稱', '重新命名', $Fav.Name)
                if ($newName) {
                    $Fav.Name = $newName
                    Persist-Favorites
                    Render-Favorites -Filter $searchBox.Text
                }
            } catch { }
        }.GetNewClosure())
        $actions.Children.Add($editTxt) | Out-Null

        $delTxt = New-Object Windows.Controls.TextBlock
        $delTxt.Text = [string][char]0xE74D
        $delTxt.FontFamily = 'Segoe MDL2 Assets'
        $delTxt.FontSize = 13
        $delTxt.Foreground = Get-Brush '#FF6C6C86'
        $delTxt.Cursor = [System.Windows.Input.Cursors]::Hand
        $delTxt.ToolTip = '刪除'
        $delTxt.Add_MouseLeftButtonDown({
            param($s2, $e2)
            try {
                $e2.Handled = $true
                $confirm = [System.Windows.MessageBox]::Show("要刪除「$($Fav.Name)」嗎?", '刪除常用專案', 'YesNo', 'Warning')
                if ($confirm -eq 'Yes') {
                    $favorites.Remove($Fav) | Out-Null
                    Persist-Favorites
                    Render-Favorites -Filter $searchBox.Text
                }
            } catch { }
        }.GetNewClosure())
        $actions.Children.Add($delTxt) | Out-Null

        [Windows.Controls.Grid]::SetColumn($actions, 2)
        $grid.Children.Add($actions) | Out-Null

        # 3: 開啟按鈕
        $openBtn = New-Object Windows.Controls.Border
        $openBtn.CornerRadius = 6
        $openBtn.Background = Get-Brush '#FF0C7ED9'
        $openBtn.Padding = '10,5'
        $openBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $openTxt = New-Object Windows.Controls.TextBlock
        $openTxt.Text = '開啟'
        $openTxt.Foreground = Get-Brush '#FFFFFFFF'
        $openTxt.FontFamily = 'Consolas'
        $openTxt.FontSize = 11
        $openTxt.FontWeight = 'Bold'
        $openBtn.Child = $openTxt
        $openBtn.Add_MouseLeftButtonDown({
            param($s2, $e2)
            try {
                $e2.Handled = $true
                Open-VsCode $Fav.Path
            } catch { }
        }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($openBtn, 3)
        $grid.Children.Add($openBtn) | Out-Null

        $card.Child = $grid

        # 點卡片其他地方(不是上面那些按鈕)一樣視同「開啟」
        $card.Add_MouseLeftButtonDown({
            param($s2, $e2)
            try {
                $e2.Handled = $true
                Open-VsCode $Fav.Path
            } catch { }
        }.GetNewClosure())

        $favList.Children.Add($card) | Out-Null
    }

    function Render-Favorites {
        param([string]$Filter = '')
        $favList.Children.Clear()

        $items = @($favorites)
        if ($Filter) {
            $items = @($items | Where-Object { $_.Name -like "*$Filter*" -or $_.Path -like "*$Filter*" })
        }
        $items = @($items | Sort-Object -Property @{Expression = { -not $_.Pinned }}, Name)

        if ($items.Count -eq 0) {
            $empty = New-Object Windows.Controls.TextBlock
            $empty.Text = if ($Filter) { '找不到符合的專案' } else { '還沒有常用專案,點右上角新增一個' }
            $empty.Foreground = Get-Brush '#FF5C5C74'
            $empty.FontFamily = 'Consolas'
            $empty.FontSize = 11
            $empty.Margin = '4,10,4,10'
            $favList.Children.Add($empty) | Out-Null
        } else {
            foreach ($fav in $items) { Add-FavRow $fav }
        }

        $countText.Text = "共 $($favorites.Count) 個專案"
    }

    # 搜尋框:輸入即時過濾,並依有沒有內容切換提示字顯示
    $searchBox.Add_TextChanged({
        try {
            $searchHint.Visibility = if ($searchBox.Text) { 'Collapsed' } else { 'Visible' }
            Render-Favorites -Filter $searchBox.Text
        } catch { }
    }.GetNewClosure())

    # 「+ 新增常用專案」:選資料夾 -> 取名 -> 存檔(跟主列表星星共用同一套邏輯)
    $addFavButton.Add_MouseLeftButtonDown({
        param($s2, $e2)
        try {
            $e2.Handled = $true
            if (Add-FavoriteInteractive $null $null) {
                $favorites.Clear()
                foreach ($item in (Get-Favorites)) { $favorites.Add($item) | Out-Null }
                Render-Favorites -Filter $searchBox.Text
            }
        } catch { }
    }.GetNewClosure())

    # 右上角關閉、標題列拖曳移動、Esc 關閉
    $closeFavButton.Add_MouseLeftButtonDown({
        param($s2, $e2)
        try { $e2.Handled = $true; $favWin.Close() } catch { }
    }.GetNewClosure())
    $closeFavButton.Add_MouseEnter({ try { $closeFavButton.Foreground = Get-Brush '#FFE06C6C' } catch { } }.GetNewClosure())
    $closeFavButton.Add_MouseLeave({ try { $closeFavButton.Foreground = Get-Brush '#FF7A7A96' } catch { } }.GetNewClosure())
    $favHeaderGrid.Add_MouseLeftButtonDown({ try { $favWin.DragMove() } catch { } }.GetNewClosure())
    $favWin.Add_KeyDown({ try { if ($_.Key -eq 'Escape') { $favWin.Close() } } catch { } }.GetNewClosure())
    $favWin.Add_Closed({ $script:favWin = $null }.GetNewClosure())

    Render-Favorites
    $favWin.Show()
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(800)
$timer.Add_Tick({ Update-Hud })

# 右上角 X 按鈕關閉
$closeButton.Add_MouseLeftButtonDown({
    param($src, $e)
    try {
        $e.Handled = $true
        $win.Close()
    } catch { }
})
$closeButton.Add_MouseEnter({ try { $closeButton.Foreground = Get-Brush '#FFE06C6C' } catch { } })
$closeButton.Add_MouseLeave({ try { $closeButton.Foreground = Get-Brush '#FF7A7A96' } catch { } })

# 標題列的「+」:開一個新的 VS Code 視窗(等同執行 `code -n`)
$addButton.Add_MouseLeftButtonDown({
    param($src, $e)
    try {
        $e.Handled = $true
        Open-VsCode $null
    } catch { }
})
$addButton.Add_MouseEnter({ try { $addButton.Opacity = 1.0 } catch { } })
$addButton.Add_MouseLeave({ try { $addButton.Opacity = 0.75 } catch { } })

# 標題列的收合圖示:開常用 VS Code 專案清單彈窗
$favButton.Add_MouseLeftButtonDown({
    param($src, $e)
    try {
        $e.Handled = $true
        Show-FavoritesWindow
    } catch { }
})
$favButton.Add_MouseEnter({ try { $favButton.Opacity = 1.0 } catch { } })
$favButton.Add_MouseLeave({ try { $favButton.Opacity = 0.75 } catch { } })

# 標題列的「↻」:不等 800ms 的計時器,馬上重新讀 state 檔案並重繪清單
$refreshButton.Add_MouseLeftButtonDown({
    param($src, $e)
    try {
        $e.Handled = $true
        Update-Hud
    } catch { }
})
$refreshButton.Add_MouseEnter({ try { $refreshButton.Foreground = Get-Brush '#FF7FB0F2' } catch { } })
$refreshButton.Add_MouseLeave({ try { $refreshButton.Foreground = Get-Brush '#FF7A7A96' } catch { } })

# 左鍵拖曳移動、右鍵或 Esc 也可以關閉
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$win.Add_MouseRightButtonUp({ try { $win.Close() } catch { } })
$win.Add_KeyDown({ try { if ($_.Key -eq 'Escape') { $win.Close() } } catch { } })

$timer.Start()
$win.ShowDialog() | Out-Null
$timer.Stop()
