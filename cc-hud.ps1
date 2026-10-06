# cc-hud.ps1
# Claude Code 狀態浮窗:永遠置頂、可拖曳、按 Esc 或右鍵關閉
# 啟動: powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File cc-hud.ps1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Win32:判斷這支程式是不是已經開了一個視窗,還有把既有的視窗叫到最前面
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class HudWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);

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

    public static void Activate(IntPtr hWnd) {
        ShowWindow(hWnd, 9); // SW_RESTORE
        SetForegroundWindow(hWnd);
    }
}
"@

# 單一實例:已經有一個在跑的話,把它叫到最前面就好,不要再開新視窗
$createdNew = $false
$appMutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeCodeHUD_SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    $existing = [HudWin32]::FindByExactTitle('Claude Code HUD')
    if ($existing -ne [IntPtr]::Zero) { [HudWin32]::Activate($existing) }
    exit
}

# 安全網:任何沒接住的例外都不要讓整個視窗當掉消失,吃掉繼續跑就好
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
    param($senderObj, $e)
    $e.Handled = $true
})

# 編譯成 .exe 之後 $PSScriptRoot 會是空的,退而用目前執行檔的實際路徑當作根目錄
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent }

# hooks-snippet.json 裡的 hook 命令固定指向 C:\Users\<you>\.claude\hud\cc-status.ps1,
# 所以狀態檔實際上都寫在那個資料夾底下 —— 不管這支 HUD 本身被複製/執行到哪裡,
# 都要讀同一個地方,不能用自己所在資料夾底下的 state(否則永遠讀不到 hook 寫的檔案)
$stateDir = Join-Path $env:USERPROFILE '.claude\hud\state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

[xml]$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Code HUD"
        Width="300" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Left="40" Top="40">
  <Border CornerRadius="10" Background="#FF1B1B26"
          BorderBrush="#FF34344A" BorderThickness="1" Padding="12,10,12,12">
    <StackPanel>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <TextBlock Name="Header" Grid.Column="0" Text="CLAUDE CODE"
                   Foreground="#FF7A7A96" FontFamily="Consolas"
                   FontSize="9" FontWeight="Bold" VerticalAlignment="Center" />
        <TextBlock Name="CloseButton" Grid.Column="1" Text="&#10005;"
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

$conv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$hex) { return $conv.ConvertFromString($hex) }

# 每種狀態的圖示、顏色、標籤
function Get-Look([string]$state) {
    switch ($state) {
        'waiting' { return @{ Icon = '[!]'; Color = '#FFFFC46B'; Label = '等你回覆' } }
        'done'    { return @{ Icon = '[v]'; Color = '#FF7FD99A'; Label = '完成'     } }
        'running' { return @{ Icon = '[>]'; Color = '#FF7FB0F2'; Label = '執行中'   } }
        'thinking'{ return @{ Icon = '[~]'; Color = '#FFB79BF2'; Label = '思考中'   } }
        default   { return @{ Icon = '[?]'; Color = '#FF6C6C86'; Label = $state     } }
    }
}

function Add-Row([string]$Icon, [string]$Color, [string]$Title, [string]$Sub) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,8,0,0'

    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = "$Icon $Title"
    $t1.Foreground = Get-Brush $Color
    $t1.FontFamily = 'Consolas'
    $t1.FontSize = 13
    $t1.TextTrimming = 'CharacterEllipsis'
    $sp.Children.Add($t1) | Out-Null

    if ($Sub) {
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = $Sub
        $t2.Foreground = Get-Brush '#FF8A8AA6'
        $t2.FontFamily = 'Consolas'
        $t2.FontSize = 11
        $t2.Margin = '22,2,0,0'
        $t2.TextTrimming = 'CharacterEllipsis'
        $sp.Children.Add($t2) | Out-Null
    }

    $list.Children.Add($sp) | Out-Null
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(800)

$timer.Add_Tick({
    # 整個 tick 包一層 try/catch,單次畫面更新失敗頂多這一輪不動,不會讓視窗整個當掉消失
    try {
        $list.Children.Clear()
        $now = Get-Date

        $files = @(Get-ChildItem -Path $stateDir -Filter '*.json' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)

        $shown = 0
        foreach ($f in $files) {
            $s = $null
            try { $s = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
            if (-not $s) { continue }

            # 超過兩小時沒動的視為死掉的 session,順手清掉
            $ts = $now
            try { $ts = [datetime]$s.ts } catch { }
            if (($now - $ts).TotalHours -gt 2) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            $look = Get-Look ([string]$s.state)

            $title = $look.Label
            if ($s.project) { $title = "$($s.project)  -  $($look.Label)" }

            $sub = [string]$s.detail
            if (-not $sub) { $sub = $ts.ToString('HH:mm:ss') }
            else { $sub = "$sub   $($ts.ToString('HH:mm:ss'))" }

            Add-Row $look.Icon $look.Color $title $sub
            $shown++
            if ($shown -ge 4) { break }
        }

        if ($shown -eq 0) {
            Add-Row '[-]' '#FF5C5C74' '沒有進行中的 session' ''
        }
    } catch { }
})

# 右上角 X 按鈕關閉(標記 Handled,避免事件冒泡到下面的拖曳處理)
$closeButton.Add_MouseLeftButtonDown({
    param($src, $e)
    try {
        $e.Handled = $true
        $win.Close()
    } catch { }
})
$closeButton.Add_MouseEnter({ try { $closeButton.Foreground = Get-Brush '#FFE06C6C' } catch { } })
$closeButton.Add_MouseLeave({ try { $closeButton.Foreground = Get-Brush '#FF7A7A96' } catch { } })

# 左鍵拖曳移動、右鍵或 Esc 也可以關閉
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$win.Add_MouseRightButtonUp({ try { $win.Close() } catch { } })
$win.Add_KeyDown({ try { if ($_.Key -eq 'Escape') { $win.Close() } } catch { } })

$timer.Start()
$win.ShowDialog() | Out-Null
$timer.Stop()
