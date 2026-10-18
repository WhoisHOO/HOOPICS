# HOOPICS window. start.bat runs this; image files dropped onto start.bat arrive as arguments.
# Keep this file ASCII-only (see HOOPICS.Core.psm1); every visible string lives in strings.json.
#
# Test hooks (used by the maintainers, harmless otherwise):
#   HOOPICS_LANG=en|ko         force the UI language
#   HOOPICS_SCREENSHOT=<png>   render the window to a PNG instead of showing it
#   HOOPICS_AUTORUN=<json>     press Start once shown, write a JSON report when done, then close

param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Path)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$CorePath = Join-Path $PSScriptRoot 'HOOPICS.Core.psm1'
$SettingsPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'HOOPICS\settings.json'
$Dot = ' ' + [char]0x00B7 + ' '
$script:T = $null

function Show-Fatal([string]$Message) {
    $text = if ($script:T) { [string]::Format([string]$script:T.Fatal, $Message) } else { $Message }
    if ($env:HOOPICS_SCREENSHOT -or $env:HOOPICS_AUTORUN) {
        # Unattended runs must not wait on a dialog nobody will click.
        [Console]::Error.WriteLine($text)
        return
    }
    [void][Windows.MessageBox]::Show($text, 'HOOPICS', 'OK', 'Error')
}

function Invoke-Safe([scriptblock]$Action) {
    # Event handlers must never throw: the console is hidden, so an error would just kill the window.
    try { & $Action } catch { Show-Fatal $_.Exception.Message }
}

function Get-Text([string]$Key) { [string]$script:T.$Key }

function Format-Text([string]$Key) { [string]::Format([string]$script:T.$Key, [object[]]$args) }

function Format-Size($Width, $Height) { Format-Text 'SizeFormat' $Width $Height }

function Get-ErrorText([string]$Message) {
    if ($Message -match '^HOOPICS:(\w+):(.*)$') {
        $code, $detail = $Matches[1], $Matches[2]
        $text = Get-Text "Err_$code"
        if ($text) {
            if ($detail -and @('Engine', 'Download', 'Save') -contains $code) { return "$text ($detail)" }
            return $text
        }
    }
    $Message
}

function Read-Settings {
    try { Get-Content -Raw -Encoding UTF8 -LiteralPath $SettingsPath | ConvertFrom-Json } catch { $null }
}

function Save-Settings($Settings) {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsPath) -Force | Out-Null
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
    } catch {
        # Remembering the language is a convenience; never fail over it.
    }
}

function Get-StartLanguage {
    if ($env:HOOPICS_LANG) { return $env:HOOPICS_LANG }
    $saved = Read-Settings
    if ($saved -and $saved.Language) { return [string]$saved.Language }
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ko') { return 'ko' }
    # Plenty of Korean users run an English Windows with Korean added as an input language.
    try { if (@(Get-WinUserLanguageList | Where-Object { $_.LanguageTag -like 'ko*' }).Count) { return 'ko' } } catch { }
    'en'
}

function New-BitmapImage([string]$File, [int]$DecodeWidth = 0, [int]$Orientation = 1) {
    # Read through a stream: no file lock, and no URI parsing trouble with '#' or '%' in paths.
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($File)
        $image = New-Object Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.StreamSource = $stream
        if ($DecodeWidth) { $image.DecodePixelWidth = $DecodeWidth }
        switch ($Orientation) {
            3 { $image.Rotation = [Windows.Media.Imaging.Rotation]::Rotate180 }
            6 { $image.Rotation = [Windows.Media.Imaging.Rotation]::Rotate90 }
            8 { $image.Rotation = [Windows.Media.Imaging.Rotation]::Rotate270 }
        }
        $image.EndInit()
        $image.Freeze()
        $image
    } catch {
        $null
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

# Runs in its own runspace so the window stays responsive; talks to the window through $Sync only.
$Worker = {
    param($CorePath, $Files, $Settings, $Sync)
    try {
        Import-Module $CorePath
        if (-not (Test-HoopicsEngine)) {
            $Sync.Stage = 'download'
            [void](Install-HoopicsEngine -State $Sync)
        }
        for ($i = 0; $i -lt $Files.Count; $i++) {
            if ($Sync.CancelRequested) { break }
            $Sync.Stage = 'image'
            $Sync.Index = $i
            $Sync.Percent = 0
            $Sync.File = [IO.Path]::GetFileName($Files[$i])
            try {
                $results = @(Invoke-HoopicsImage -Path $Files[$i] -Target $Settings.Targets -Model $Settings.Model `
                        -Mode $Settings.Mode -Format $Settings.Format -State $Sync)
                foreach ($result in $results) {
                    if (-not $Sync.Results.Contains($result.Path)) { [void]$Sync.Results.Add($result.Path) }
                }
                if ($Settings.Monitors) {
                    # Targets were the monitors themselves, so result N belongs to monitor N.
                    for ($m = 0; $m -lt $Settings.Monitors.Count; $m++) {
                        Set-HoopicsWallpaper -MonitorId $Settings.Monitors[$m].Id -Path $results[$m].Path
                    }
                    $Sync.WallpaperSet = $true
                }
            } catch {
                if ($Sync.CancelRequested) { break }
                [void]$Sync.Errors.Add(@($Sync.File, $_.Exception.Message))
            }
        }
    } catch {
        $Sync.Fatal = $_.Exception.Message
    } finally {
        $Sync.Done = $true
    }
}

try {
    Import-Module $CorePath -Force
    [Hoopics.Dpi]::Enable()

    $Strings = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'strings.json') | ConvertFrom-Json
    $script:T = $Strings.en

    [xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'MainWindow.xaml')
    $window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
    $ui = @{}
    foreach ($node in $xaml.SelectNodes('//*')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) { $ui[$name] = $window.FindName($name) }
    }

    $logo = New-BitmapImage (Join-Path (Split-Path -Parent $PSScriptRoot) 'HOO_Logo.jpg') 128
    if ($logo) {
        $ui.Logo.Source = $logo
        $window.Icon = $logo
    }

    $script:Files = @()
    $script:Info = $null
    $script:Job = $null
    $script:LastResults = @()
    $script:Monitors = @()
    try { $script:Monitors = @(Get-HoopicsMonitor) } catch { $script:Monitors = @() }

    $primary = $script:Monitors | Where-Object Primary | Select-Object -First 1
    $ui.CustomWidth.Text = if ($primary) { [string]$primary.Width } else { '1920' }
    $ui.CustomHeight.Text = if ($primary) { [string]$primary.Height } else { '1080' }

    function Get-Category {
        foreach ($chip in $ui.Categories.Children) { if ($chip.IsChecked) { return [string]$chip.Tag } }
        'screen'
    }

    function Get-Mode { if ($ui.ModeFit.IsChecked) { 'fit' } else { 'fill' } }

    function Get-Format { if ($ui.FormatJpg.IsChecked) { 'jpg' } else { 'png' } }

    function Get-MonitorLabel($Monitor) {
        $name = if ($Monitor.Internal) { Get-Text 'ScreenInternal' } elseif ($Monitor.Name) { $Monitor.Name } else { Format-Text 'ScreenGeneric' $Monitor.Number }
        $label = $name + $Dot + (Format-Size $Monitor.Width $Monitor.Height)
        if ($Monitor.Primary -and $script:Monitors.Count -gt 1) { $label += $Dot + (Get-Text 'ScreenPrimary') }
        $label
    }

    function Add-Choice([string]$Text, $Value) {
        $item = New-Object Windows.Controls.ComboBoxItem
        $item.Content = $Text
        $item.Tag = $Value
        [void]$ui.ResolutionBox.Items.Add($item)
    }

    function Get-Selection {
        # @{ Targets; Monitors } for the current choice, or $null when nothing usable is selected.
        $category = Get-Category
        if ($category -eq 'custom') {
            $width = 0
            $height = 0
            $valid = [int]::TryParse($ui.CustomWidth.Text.Trim(), [ref]$width) -and [int]::TryParse($ui.CustomHeight.Text.Trim(), [ref]$height)
            if ($valid -and $width -ge 16 -and $height -ge 16 -and $width -le 16384 -and $height -le 16384) {
                return @{ Targets = @(@{ Width = $width; Height = $height }); Monitors = $null }
            }
            return $null
        }
        $item = $ui.ResolutionBox.SelectedItem
        if (-not $item -or $null -eq $item.Tag) { return $null }
        if ($category -eq 'screen') { return @{ Targets = @($item.Tag); Monitors = @($item.Tag) } }
        if ($category -eq 'scale') { return @{ Targets = @(@{ Scale = [double]$item.Tag }); Monitors = $null } }
        @{ Targets = @($item.Tag); Monitors = $null }
    }

    function Update-EnabledState {
        $idle = -not $script:Job
        $category = Get-Category
        foreach ($name in 'Categories', 'ResolutionBox', 'CustomPanel', 'ModelBox', 'FormatPng', 'FormatJpg', 'DropZone', 'LanguageButton') {
            $ui[$name].IsEnabled = $idle
        }
        if ($category -eq 'screen' -and $script:Monitors.Count -eq 0) { $ui.ResolutionBox.IsEnabled = $false }
        # Enlarging by a factor keeps the shape, so fill/fit does not apply.
        $ui.ModeFill.IsEnabled = $idle -and $category -ne 'scale'
        $ui.ModeFit.IsEnabled = $idle -and $category -ne 'scale'
        $single = $script:Files.Count -le 1
        $ui.SetWallpaper.Content = if ($single) { Get-Text 'SetWallpaper' } else { Get-Text 'SetWallpaperOne' }
        if (-not $single) { $ui.SetWallpaper.IsChecked = $false }
        $ui.SetWallpaper.IsEnabled = $idle -and $single
    }

    function Update-Summary {
        $ready = $false
        if (-not $script:Files.Count) {
            $ui.Summary.Text = Get-Text 'SummaryNoFile'
        } else {
            $selection = Get-Selection
            if (-not $selection) {
                $ui.Summary.Text = if ((Get-Category) -eq 'custom') { Get-Text 'InvalidCustom' } else { Get-Text 'NoScreens' }
            } elseif (-not $script:Info) {
                $ui.Summary.Text = ''
                $ready = $true
            } else {
                $plan = Get-HoopicsPlan -SourceWidth $script:Info.Width -SourceHeight $script:Info.Height -Target $selection.Targets -Mode (Get-Mode)
                $sizes = ($plan.Sizes | ForEach-Object { Format-Size $_.Width $_.Height } | Select-Object -Unique) -join ' + '
                if ($plan.TooSmall) {
                    $ui.Summary.Text = Format-Text 'SummaryTooSmall' $plan.Scale
                } elseif ($plan.Passes -gt 0) {
                    $ui.Summary.Text = Format-Text 'SummaryAi' $sizes $plan.Scale
                    $ready = $true
                } else {
                    $ui.Summary.Text = Format-Text 'SummaryNoAi' $sizes
                    $ready = $true
                }
            }
        }
        $ui.StartButton.IsEnabled = $ready -or [bool]$script:Job
    }

    function Update-Choices([switch]$KeepSelection) {
        $category = Get-Category
        $keep = if ($KeepSelection) { $ui.ResolutionBox.SelectedIndex } else { 0 }
        $ui.ResolutionBox.Items.Clear()
        $custom = $category -eq 'custom'
        $ui.ResolutionBox.Visibility = if ($custom) { 'Collapsed' } else { 'Visible' }
        $ui.CustomPanel.Visibility = if ($custom) { 'Visible' } else { 'Collapsed' }
        $ui.SetWallpaper.Visibility = if ($category -eq 'screen') { 'Visible' } else { 'Collapsed' }
        switch ($category) {
            'screen' {
                if ($script:Monitors.Count -gt 1) {
                    $sizes = ($script:Monitors | ForEach-Object { Format-Size $_.Width $_.Height }) -join ' + '
                    Add-Choice (Format-Text 'AllScreens' $script:Monitors.Count $sizes) $script:Monitors
                }
                foreach ($monitor in $script:Monitors) { Add-Choice (Get-MonitorLabel $monitor) @($monitor) }
                if ($script:Monitors.Count -eq 0) { Add-Choice (Get-Text 'NoScreens') $null }
            }
            'scale' {
                foreach ($factor in 2, 3, 4) { Add-Choice (Format-Text 'ScaleItem' $factor) $factor }
            }
            'custom' { }
            default {
                foreach ($preset in Get-HoopicsPreset -Category $category) {
                    $text = $preset.Label + $Dot + (Format-Size $preset.Width $preset.Height)
                    if ($preset.Ratio) { $text += " ($($preset.Ratio))" }
                    Add-Choice $text $preset
                }
            }
        }
        if ($ui.ResolutionBox.Items.Count) { $ui.ResolutionBox.SelectedIndex = [Math]::Max(0, [Math]::Min($keep, $ui.ResolutionBox.Items.Count - 1)) }
        Update-EnabledState
        Update-Summary
    }

    function Update-FileText {
        if (-not $script:Files.Count) { return }
        $name = [IO.Path]::GetFileName($script:Files[0])
        $ui.FileName.Text = if ($script:Files.Count -gt 1) { Format-Text 'FilesMore' $name ($script:Files.Count - 1) } else { $name }
        $ui.FileInfo.Text = if ($script:Info) { Format-Text 'FileInfo' $script:Info.Width $script:Info.Height } else { '' }
    }

    function Set-Language([string]$Language) {
        $script:Language = if ($Strings.$Language) { $Language } else { 'en' }
        $script:T = $Strings.$script:Language
        # Controls whose text key in strings.json is their own name.
        foreach ($key in 'Subtitle', 'DropTitle', 'DropSub', 'DropChange', 'StepDevice', 'StepResolution', 'StepModel', 'StepMode', 'FormatLabel') {
            $ui[$key].Text = Get-Text $key
        }
        foreach ($key in 'CatScreen', 'CatLaptop', 'CatMonitor', 'CatPhone', 'CatScale', 'CatCustom', 'ModeFill', 'ModeFit', 'FormatPng', 'FormatJpg', 'OpenFolder') {
            $ui[$key].Content = Get-Text $key
        }
        $ui.LanguageButton.Content = Get-Text 'SwitchLanguage'
        $ui.StartButton.Content = Get-Text 'Start'
        $ui.Footer.Text = Format-Text 'Footer' (Get-HoopicsVersion)

        $selected = [Math]::Max(0, $ui.ModelBox.SelectedIndex)
        $ui.ModelBox.Items.Clear()
        $models = [ordered]@{ 'anime' = 'ModelAnime'; 'anime-sharp' = 'ModelAnimeSharp'; 'photo' = 'ModelPhoto' }
        foreach ($model in $models.Keys) {
            $item = New-Object Windows.Controls.ComboBoxItem
            $item.Content = Get-Text $models[$model]
            $item.Tag = $model
            [void]$ui.ModelBox.Items.Add($item)
        }
        $ui.ModelBox.SelectedIndex = $selected
        $ui.Status.Text = ''
        Update-FileText
        Update-Choices -KeepSelection
    }

    function Set-Files([string[]]$Paths) {
        $extensions = Get-HoopicsInputExtension
        $found = New-Object Collections.Generic.List[string]
        foreach ($candidate in $Paths) {
            if (-not $candidate) { continue }
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                Get-ChildItem -LiteralPath $candidate -File | Sort-Object Name |
                    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                    ForEach-Object { $found.Add($_.FullName) }
            } elseif ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
                ($extensions -contains [IO.Path]::GetExtension($candidate).ToLowerInvariant())) {
                $found.Add((Resolve-Path -LiteralPath $candidate).ProviderPath)
            }
        }
        if ($found.Count -eq 0) {
            if ($Paths) { $ui.Status.Text = Get-Text 'Unsupported' }
            return
        }
        $script:Files = @($found | Select-Object -Unique)
        $script:Info = Get-HoopicsImageInfo $script:Files[0]
        $orientation = if ($script:Info) { $script:Info.Orientation } else { 1 }
        $ui.Thumb.Source = New-BitmapImage $script:Files[0] 420 $orientation
        Update-FileText
        $ui.DropHint.Visibility = 'Collapsed'
        $ui.Preview.Visibility = 'Visible'
        $ui.Status.Text = ''
        $ui.OpenFolder.Visibility = 'Collapsed'
        Update-EnabledState
        Update-Summary
    }

    function Show-OpenDialog {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = Get-Text 'OpenDialogTitle'
        $dialog.Filter = Get-Text 'OpenDialogFilter'
        $dialog.Multiselect = $true
        if ($dialog.ShowDialog($window)) { Set-Files $dialog.FileNames }
    }

    function Set-Busy([bool]$Busy) {
        $ui.StartButton.Content = if ($Busy) { Get-Text 'Cancel' } else { Get-Text 'Start' }
        $ui.Progress.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
        $ui.Progress.Value = 0
        if ($Busy) {
            $ui.Status.Text = ''
            $ui.OpenFolder.Visibility = 'Collapsed'
        }
        Update-EnabledState
        Update-Summary
    }

    function Start-Conversion {
        $selection = Get-Selection
        if (-not $selection -or -not $script:Files.Count) { return }
        $wallpaper = $ui.SetWallpaper.IsChecked -and (Get-Category) -eq 'screen' -and $script:Files.Count -eq 1
        $settings = @{
            Targets  = $selection.Targets
            Monitors = if ($wallpaper) { $selection.Monitors } else { $null }
            Model    = [string]$ui.ModelBox.SelectedItem.Tag
            Mode     = Get-Mode
            Format   = Get-Format
        }
        $sync = [hashtable]::Synchronized(@{
                Stage = 'start'; Percent = 0.0; Index = 0; Count = $script:Files.Count; File = ''
                Done = $false; CancelRequested = $false; Process = $null; Fatal = $null; WallpaperSet = $false
                Results = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
                Errors = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
            })
        $sessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
        $runspace = [RunspaceFactory]::CreateRunspace($sessionState)
        $runspace.ApartmentState = 'STA'
        $runspace.Open()
        $shell = [PowerShell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript($Worker).AddArgument($CorePath).AddArgument($script:Files).AddArgument($settings).AddArgument($sync)
        $script:Job = @{ Shell = $shell; Handle = $shell.BeginInvoke(); Sync = $sync }
        Set-Busy $true
        $timer.Start()
    }

    function Stop-Conversion {
        $sync = $script:Job.Sync
        $sync.CancelRequested = $true
        $process = $sync.Process
        if ($process) { try { $process.Kill() } catch { } }
        $ui.StartButton.IsEnabled = $false
    }

    function Complete-Conversion {
        $timer.Stop()
        $job = $script:Job
        $script:Job = $null
        try { [void]$job.Shell.EndInvoke($job.Handle) } catch { }
        $job.Shell.Runspace.Dispose()
        $job.Shell.Dispose()

        $sync = $job.Sync
        $script:LastResults = @($sync.Results)
        $lines = New-Object Collections.Generic.List[string]
        if ($sync.CancelRequested) {
            $lines.Add((Get-Text 'StatusCanceled'))
        } elseif ($sync.Fatal) {
            $lines.Add((Get-ErrorText $sync.Fatal))
        } else {
            if ($sync.Results.Count) { $lines.Add((Format-Text 'StatusDone' $sync.Results.Count)) }
            if ($sync.WallpaperSet) { $lines.Add((Get-Text 'StatusWallpaper')) }
        }
        foreach ($failure in $sync.Errors) { $lines.Add((Format-Text 'StatusFailed' $failure[0] (Get-ErrorText $failure[1]))) }
        $ui.Status.Text = $lines -join "`n"
        $ui.OpenFolder.Visibility = if ($script:LastResults.Count) { 'Visible' } else { 'Collapsed' }
        Set-Busy $false

        if ($env:HOOPICS_AUTORUN) {
            @{ Status = $ui.Status.Text; Results = $script:LastResults; Errors = @($sync.Errors | ForEach-Object { $_[1] }) } |
                ConvertTo-Json | Set-Content -LiteralPath $env:HOOPICS_AUTORUN -Encoding UTF8
            $window.Close()
        }
    }

    function Update-Progress {
        $job = $script:Job
        if (-not $job) { $timer.Stop(); return }
        $sync = $job.Sync
        if ($sync.Stage -eq 'download') {
            $ui.Progress.Value = $sync.Percent
            $ui.Status.Text = Format-Text 'StatusDownload' $sync.Percent
        } elseif ($sync.Stage -eq 'image') {
            $ui.Progress.Value = 100 * ($sync.Index + $sync.Percent / 100) / $sync.Count
            $ui.Status.Text = Format-Text 'StatusWorking' ($sync.Index + 1) $sync.Count $sync.File $sync.Percent
        }
        if ($sync.Done) { Complete-Conversion }
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Invoke-Safe { Update-Progress } })

    foreach ($chip in $ui.Categories.Children) { $chip.Add_Checked({ Invoke-Safe { Update-Choices } }) }
    $ui.ResolutionBox.Add_SelectionChanged({ Invoke-Safe { Update-Summary } })
    $ui.ModeFill.Add_Checked({ Invoke-Safe { Update-Summary } })
    $ui.ModeFit.Add_Checked({ Invoke-Safe { Update-Summary } })
    $ui.CustomWidth.Add_TextChanged({ Invoke-Safe { Update-Summary } })
    $ui.CustomHeight.Add_TextChanged({ Invoke-Safe { Update-Summary } })
    $ui.StartButton.Add_Click({ Invoke-Safe { if ($script:Job) { Stop-Conversion } else { Start-Conversion } } })
    $ui.LanguageButton.Add_Click({
            Invoke-Safe {
                $next = if ($script:Language -eq 'ko') { 'en' } else { 'ko' }
                Set-Language $next
                Save-Settings @{ Language = $next }
            }
        })
    $ui.OpenFolder.Add_Click({
            Invoke-Safe {
                if ($script:LastResults.Count) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $script:LastResults[0]) }
            }
        })
    $ui.DropZone.Add_MouseLeftButtonUp({ Invoke-Safe { if (-not $script:Job) { Show-OpenDialog } } })

    $idleBorder = $ui.DropBorder.Stroke
    $window.Add_DragOver({
            param($control, $e)
            $accept = -not $script:Job -and $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)
            $e.Effects = if ($accept) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }
            if ($accept) { $ui.DropBorder.Stroke = [Windows.Media.Brushes]::Black }
            $e.Handled = $true
        })
    $window.Add_DragLeave({ $ui.DropBorder.Stroke = $idleBorder })
    $window.Add_Drop({
            param($control, $e)
            Invoke-Safe {
                $ui.DropBorder.Stroke = $idleBorder
                if (-not $script:Job -and $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
                    Set-Files ([string[]]$e.Data.GetData([Windows.DataFormats]::FileDrop))
                }
            }
        })
    $window.Add_Closing({ if ($script:Job) { Stop-Conversion } })

    if ($script:Monitors.Count) { $ui.CatScreen.IsChecked = $true } else { $ui.CatMonitor.IsChecked = $true }
    Set-Language (Get-StartLanguage)
    if ($Path) { Set-Files $Path }

    if ($env:HOOPICS_SCREENSHOT) {
        # Lay the window content out off-screen and save it as a PNG at 150% scale.
        $ui.Root.Background = $window.Background
        $ui.Root.Measure((New-Object Windows.Size 584, ([double]::PositiveInfinity)))
        $height = $ui.Root.DesiredSize.Height   # includes the margins, unlike ActualHeight
        $ui.Root.Arrange((New-Object Windows.Rect 0, 0, 584, $height))
        $ui.Root.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap -ArgumentList 876, ([int][Math]::Ceiling($height * 1.5)), 144, 144, ([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($ui.Root)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $file = [IO.File]::Create($env:HOOPICS_SCREENSHOT)
        try { $encoder.Save($file) } finally { $file.Dispose() }
        return
    }
    if ($env:HOOPICS_AUTORUN) {
        $window.Add_ContentRendered({ Invoke-Safe { Start-Conversion } })
    }

    [void]$window.ShowDialog()
} catch {
    Show-Fatal $_.Exception.Message
    exit 1
}
