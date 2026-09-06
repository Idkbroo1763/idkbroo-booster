$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# PS2EXE alatt a $PSScriptRoot üres lehet. Ilyenkor az EXE saját mappáját
# használjuk minden alkalmazáshoz tartozó fájl és parancsikon alapjaként.
$script:isPackagedExe = [string]::IsNullOrWhiteSpace($PSScriptRoot)
$script:appDirectory = if ($script:isPackagedExe) {
    [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar)
} else {
    $PSScriptRoot
}
$script:appLaunchPath = if ($script:isPackagedExe) {
    [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
} else {
    Join-Path $script:appDirectory 'TudomHogyMelegVagy.bat'
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AudioAppNative {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    enum EDataFlow { eRender, eCapture, eAll }
    enum ERole { eConsole, eMultimedia, eCommunications }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    interface IMMDevice {
        int Activate(ref Guid iid, uint context, IntPtr activationParams, out IntPtr instance);
        int OpenPropertyStore(uint access, out IPropertyStore properties);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore {
        int GetCount(out uint count);
        int GetAt(uint index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    }

    [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)] struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    public static string GetDefaultOutputName() {
        IMMDeviceEnumerator enumerator = null; IMMDevice device = null; IPropertyStore store = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            if (enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device) != 0) return "Ismeretlen";
            if (device.OpenPropertyStore(0, out store) != 0) return "Ismeretlen";
            var key = new PROPERTYKEY { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };
            PROPVARIANT value;
            if (store.GetValue(ref key, out value) != 0 || value.pointerValue == IntPtr.Zero) return "Ismeretlen";
            return Marshal.PtrToStringUni(value.pointerValue) ?? "Ismeretlen";
        } catch { return "Ismeretlen"; }
        finally {
            if (store != null) Marshal.ReleaseComObject(store);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }
}
"@

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ApoConfigDirectory {
    $candidates = @(
        "$env:ProgramFiles\EqualizerAPO\config",
        "${env:ProgramFiles(x86)}\EqualizerAPO\config"
    ) | Where-Object { $_ -and (Test-Path $_) }
    return $candidates | Select-Object -First 1
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Tudom, hogy meleg vagy V4" Width="1180" Height="840" MinWidth="1000" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#080A10" Foreground="#F8FAFC"
        FontFamily="Segoe UI">
  <Window.Resources>
    <LinearGradientBrush x:Key="PageGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#090B12" Offset="0"/><GradientStop Color="#11102A" Offset="0.55"/><GradientStop Color="#090B12" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="AccentGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8B5CF6" Offset="0"/><GradientStop Color="#6D28D9" Offset="1"/>
    </LinearGradientBrush>
    <DropShadowEffect x:Key="CardShadow" BlurRadius="22" ShadowDepth="4" Opacity="0.25" Color="#000000"/>
    <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe UI"/></Style>
    <Style TargetType="Button">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#E9E7FF"/><Setter Property="Background" Value="#1B2030"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="15,10"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#2B2650"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource AccentGradient}"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/><Setter Property="Padding" Value="24,14"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="UtilityButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Padding" Value="12,8"/><Setter Property="Margin" Value="0,0,7,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#CBD5E1"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,4,18,4"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Height" Value="34"/><Setter Property="Margin" Value="0,7,0,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid>
              <Border Height="8" CornerRadius="4" Background="#252B3C" VerticalAlignment="Center"/>
              <Track Name="PART_Track" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Background="{StaticResource AccentGradient}" BorderThickness="0">
                    <RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="{TemplateBinding Background}" CornerRadius="4"/></ControlTemplate></RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="22" Height="22" Cursor="Hand">
                    <Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Fill="#FFFFFF" Stroke="#8B5CF6" StrokeThickness="5"/></ControlTemplate></Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Background="Transparent" BorderThickness="0"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="VerticalEqSlider" TargetType="Slider">
      <Setter Property="Width" Value="40"/><Setter Property="Height" Value="120"/>
      <Setter Property="Margin" Value="2"/><Setter Property="Orientation" Value="Vertical"/>
    </Style>
  </Window.Resources>

  <Grid Background="{StaticResource PageGradient}">
    <Grid.RowDefinitions><RowDefinition Height="96"/><RowDefinition Height="*"/></Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="30,20,30,13">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="440"/></Grid.ColumnDefinitions>
      <StackPanel VerticalAlignment="Center">
        <TextBlock Text="TUDOM, HOGY MELEG VAGY" FontFamily="Segoe UI Black" FontSize="29" Foreground="#A78BFA"/>
        <TextBlock Text="S Y S T E M   A U D I O   C O N T R O L  •  V4" FontSize="11" FontWeight="Bold" Foreground="#64748B" Margin="1,3,0,0"/>
      </StackPanel>
      <Border Name="StatusBorder" Grid.Column="1" Background="#151927" CornerRadius="13" Padding="16,11" BorderBrush="#262C3D" BorderThickness="1">
        <StackPanel>
          <TextBlock Name="StatusText" Text="Equalizer APO keresése..." FontSize="13" FontWeight="SemiBold" Foreground="#E2E8F0"/>
          <TextBlock Name="DeviceText" Text="Aktív hangkimenet: keresés..." FontSize="12" Foreground="#8B9BB4" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="1" Margin="30,0,30,28">
      <Grid.ColumnDefinitions><ColumnDefinition Width="245"/><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#111520" CornerRadius="18" Padding="16" BorderBrush="#24293A" BorderThickness="1" Effect="{StaticResource CardShadow}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="P R O F I L O K" FontSize="11" FontWeight="Bold" Foreground="#6E7A91" Margin="5,2,0,13"/>
          <StackPanel Grid.Row="1">
            <Button Name="MusicButton" Content="♫   Zene"/>
            <Button Name="GameButton" Content="◆   FiveM RP"/>
            <Button Name="CombatButton" Content="⌁   FiveM harc"/>
            <Button Name="R6Button" Content="◎   Rainbow Six"/>
            <Button Name="DiscordButton" Content="◉   Discord"/>
            <Button Name="MovieButton" Content="▶   Film"/>
            <Button Name="HeavyButton" Content="ϟ   Brutál basszus"/>
            <Button Name="ResetButton" Content="↺   Alaphelyzet"/>
          </StackPanel>
          <StackPanel Grid.Row="2">
            <Border Height="1" Background="#272D3E" Margin="0,4,0,13"/>
            <TextBlock Name="ActiveProfileText" Text="Aktív profil: Custom" Foreground="#A78BFA" FontWeight="SemiBold" FontSize="12" Margin="4,0,0,10"/>
            <Button Name="ApplyButton" Content="ALKALMAZÁS" Style="{StaticResource PrimaryButton}"/>
          </StackPanel>
        </Grid>
      </Border>

      <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <Border Background="#111520" CornerRadius="18" Padding="22,17" BorderBrush="#24293A" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel>
                <DockPanel><TextBlock Text="Hangerő-erősítés" FontSize="15" FontWeight="SemiBold"/><TextBlock Name="VolumeValue" Text="100%" FontSize="17" FontWeight="Bold" Foreground="#A78BFA" HorizontalAlignment="Right"/></DockPanel>
                <Slider Name="VolumeSlider" Minimum="0" Maximum="300" Value="100" TickFrequency="5" IsSnapToTickEnabled="True"/>
                <TextBlock Text="Teljes tartomány: némítás–300%" FontSize="11" Foreground="#64748B"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <DockPanel><TextBlock Text="Bass Boost" FontSize="15" FontWeight="SemiBold"/><TextBlock Name="BassValue" Text="6 dB" FontSize="17" FontWeight="Bold" Foreground="#A78BFA" HorizontalAlignment="Right"/></DockPanel>
                <Slider Name="BassSlider" Minimum="0" Maximum="24" Value="6" TickFrequency="1" IsSnapToTickEnabled="True"/>
                <TextBlock Text="Többsávos mélyhangkiemelés" FontSize="11" Foreground="#64748B"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Background="#111520" CornerRadius="18" Padding="22,17" BorderBrush="#24293A" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <DockPanel>
                <TextBlock Text="Basszus középfrekvencia" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock Name="FrequencyValue" Text="75 Hz" FontSize="17" FontWeight="Bold" Foreground="#A78BFA" HorizontalAlignment="Right"/>
              </DockPanel>
              <Slider Name="FrequencySlider" Grid.Row="1" Minimum="40" Maximum="160" Value="75" TickFrequency="5" IsSnapToTickEnabled="True"/>
            </Grid>
          </Border>

          <Border Background="#111520" CornerRadius="18" Padding="22,15" BorderBrush="#24293A" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="V É D E L E M   É S   A U T O M A T I Z Á L Á S" FontSize="11" FontWeight="Bold" Foreground="#6E7A91" Margin="0,0,0,8"/>
                <WrapPanel>
                  <CheckBox Name="SafetyCheck" Content="Torzításvédelem" IsChecked="True"/>
                  <CheckBox Name="AutoProfileCheck" Content="Automatikus profilváltás"/>
                  <CheckBox Name="InstantCheck" Content="Azonnali alkalmazás"/>
                  <CheckBox Name="StartupCheck" Content="Indulás a Windowszal"/>
                </WrapPanel>
              </StackPanel>
              <Border Grid.Column="1" Background="#12291F" CornerRadius="9" Padding="12,7" VerticalAlignment="Center">
                <TextBlock Name="ClipText" Text="VÉDVE" Foreground="#4ADE80" FontWeight="Bold" FontSize="11"/>
              </Border>
            </Grid>
          </Border>

          <Border Background="#111520" CornerRadius="18" Padding="22,15" BorderBrush="#24293A" BorderThickness="1" Effect="{StaticResource CardShadow}" Margin="0,0,0,14">
            <StackPanel>
              <DockPanel Margin="0,0,0,10">
                <TextBlock Text="1 0   S Á V O S   E Q U A L I Z E R" FontSize="11" FontWeight="Bold" Foreground="#6E7A91"/>
                <TextBlock Text="-12 dB  •  +12 dB" HorizontalAlignment="Right" Foreground="#64748B" FontSize="11"/>
              </DockPanel>
              <Border Background="#0B0E16" CornerRadius="12" Padding="12">
                <UniformGrid Name="EqPanel" Rows="1" Columns="10"/>
              </Border>
            </StackPanel>
          </Border>

          <Border Background="#111520" CornerRadius="18" Padding="18,14" BorderBrush="#24293A" BorderThickness="1">
            <StackPanel>
              <TextBlock Text="E S Z K Ö Z Ö K   É S   P R O F I L K E Z E L É S" FontSize="11" FontWeight="Bold" Foreground="#6E7A91" Margin="4,0,0,10"/>
              <WrapPanel>
                <Button Name="SaveButton" Content="Saját mentés" Style="{StaticResource UtilityButton}"/>
                <Button Name="LoadButton" Content="Saját betöltés" Style="{StaticResource UtilityButton}"/>
                <Button Name="ExportButton" Content="Export" Style="{StaticResource UtilityButton}"/>
                <Button Name="ImportButton" Content="Import" Style="{StaticResource UtilityButton}"/>
                <Button Name="UndoButton" Content="Visszavonás" Style="{StaticResource UtilityButton}"/>
                <Button Name="BypassButton" Content="Kikapcsolás" Style="{StaticResource UtilityButton}" Background="#4A2331"/>
                <Button Name="TestButton" Content="60 Hz teszt" Style="{StaticResource UtilityButton}"/>
                <Button Name="DeviceButton" Content="Hangeszközök" Style="{StaticResource UtilityButton}"/>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$appIconPath = Join-Path $script:appDirectory 'idkbroo Booster.ico'
if (Test-Path $appIconPath) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$appIconPath) } catch { }
}
$names = @('StatusBorder','StatusText','DeviceText','VolumeValue','BassValue','FrequencyValue','VolumeSlider','BassSlider','FrequencySlider','SafetyCheck','MusicButton','GameButton','CombatButton','R6Button','DiscordButton','MovieButton','HeavyButton','ResetButton','ApplyButton','EqPanel','AutoProfileCheck','InstantCheck','StartupCheck','ClipText','SaveButton','LoadButton','ExportButton','ImportButton','UndoButton','BypassButton','TestButton','DeviceButton','ActiveProfileText')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }

$script:eqBands = @(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
$script:eqSliders = @()
$script:eqValueLabels = @()
for ($i = 0; $i -lt $script:eqBands.Count; $i++) {
    $column = New-Object Windows.Controls.StackPanel
    $column.HorizontalAlignment = 'Center'
    $bandLabel = New-Object Windows.Controls.TextBlock
    $bandLabel.Text = if ($script:eqBands[$i] -ge 1000) { "$($script:eqBands[$i] / 1000)k" } else { "$($script:eqBands[$i])" }
    $bandLabel.HorizontalAlignment = 'Center'; $bandLabel.Foreground = '#AAB2C0'
    $slider = New-Object Windows.Controls.Slider
    $slider.Minimum = -12; $slider.Maximum = 12; $slider.Value = 0; $slider.TickFrequency = 1; $slider.IsSnapToTickEnabled = $true
    $slider.Style = $window.FindResource('VerticalEqSlider')
    $valueLabel = New-Object Windows.Controls.TextBlock
    $valueLabel.Text = '0'; $valueLabel.HorizontalAlignment = 'Center'; $valueLabel.Foreground = '#A78BFA'
    [void]$column.Children.Add($bandLabel); [void]$column.Children.Add($slider); [void]$column.Children.Add($valueLabel)
    [void]$EqPanel.Children.Add($column)
    $script:eqSliders += $slider; $script:eqValueLabels += $valueLabel
    $index = $i
    $slider.Add_ValueChanged({ $script:eqValueLabels[$index].Text = ([int]$script:eqSliders[$index].Value).ToString() }.GetNewClosure())
}

function Set-EqValues([double[]]$values) {
    for ($i = 0; $i -lt $script:eqSliders.Count; $i++) { $script:eqSliders[$i].Value = $values[$i] }
}

function Update-Labels {
    $VolumeValue.Text = "$([int]$VolumeSlider.Value)%"
    $BassValue.Text = "$([int]$BassSlider.Value) dB"
    $FrequencyValue.Text = "$([int]$FrequencySlider.Value) Hz"
    $roughVolumeDb = if ([double]$VolumeSlider.Value -le 0) { -100.0 } else { 20.0 * [Math]::Log10([double]$VolumeSlider.Value / 100.0) }
    $roughPeak = $roughVolumeDb + ([double]$BassSlider.Value * 0.55)
    if ($SafetyCheck.IsChecked) {
        $ClipText.Text = 'VÉDVE'; $ClipText.Foreground = '#4ADE80'
    } elseif ($roughPeak -gt 6) {
        $ClipText.Text = 'TORZÍTÁSVESZÉLY'; $ClipText.Foreground = '#FB7185'
    } else {
        $ClipText.Text = 'OK'; $ClipText.Foreground = '#FBBF24'
    }
}

function Set-Profile([int]$volume, [int]$bass, [int]$frequency, [bool]$safe = $true) {
    $VolumeSlider.Value = $volume; $BassSlider.Value = $bass; $FrequencySlider.Value = $frequency
    $SafetyCheck.IsChecked = $safe; $ActiveProfileText.Text = "Aktív profil: $script:activeProfile"; Update-Labels
}

$VolumeSlider.Add_ValueChanged({ Update-Labels })
$BassSlider.Add_ValueChanged({ Update-Labels })
$FrequencySlider.Add_ValueChanged({ Update-Labels })
$script:activeProfile = 'Custom'
$MusicButton.Add_Click({ $script:activeProfile = 'Music'; Set-Profile 170 5 72 $true; Set-EqValues @(2,2,1,-1,-1,0,1,2,1,1) })
$GameButton.Add_Click({ $script:activeProfile = 'FiveM RP'; Set-Profile 135 2 85 $true; Set-EqValues @(-1,0,1,-1,-1,0,2,2,1,0) })
$CombatButton.Add_Click({ $script:activeProfile = 'FiveM Combat'; Set-Profile 130 1 90 $true; Set-EqValues @(-3,-2,-1,-1,0,1,3,3,2,0) })
$R6Button.Add_Click({ $script:activeProfile = 'R6'; Set-Profile 135 1 90 $true; Set-EqValues @(-2,-1,0,-1,-1,0,2,3,1,0) })
$DiscordButton.Add_Click({ $script:activeProfile = 'Discord'; Set-Profile 130 0 80 $true; Set-EqValues @(-6,-5,-4,-2,0,2,4,3,0,-1) })
$MovieButton.Add_Click({ $script:activeProfile = 'Movie'; Set-Profile 145 6 65 $true; Set-EqValues @(2,2,1,0,0,1,2,2,1,1) })
$HeavyButton.Add_Click({ $script:activeProfile = 'Heavy'; Set-Profile 180 12 60 $true; Set-EqValues @(2,1,0,0,0,0,0,0,0,0) })
$ResetButton.Add_Click({ $script:activeProfile = 'Custom'; Set-Profile 100 0 75 $true; Set-EqValues @(0,0,0,0,0,0,0,0,0,0) })

$apoDirectory = Get-ApoConfigDirectory
if ($apoDirectory) {
    $StatusText.Text = "OK - Equalizer APO megtalálva, készen áll"
    $StatusBorder.Background = '#143126'
} else {
    $StatusText.Text = "FIGYELEM - Equalizer APO nincs telepítve, lásd a TELEPITES.txt fájlt"
    $StatusBorder.Background = '#3A2812'
}

function Read-TextWithRetry([string]$path) {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { return [IO.File]::ReadAllText($path) }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

function Write-LinesWithRetry([string]$path, [string[]]$lines) {
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { [IO.File]::WriteAllLines($path, $lines, $encoding); return }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

function Write-TextWithRetry([string]$path, [string]$value) {
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try { [IO.File]::WriteAllText($path, $value, $encoding); return }
        catch [IO.IOException] { if ($attempt -eq 20) { throw }; [Threading.Thread]::Sleep(100) }
    }
}

$script:applyBusy = $false
$ApplyButton.Add_Click({
    if ($script:applyBusy) { return }
    $script:applyBusy = $true
    try {
        $apoDirectory = Get-ApoConfigDirectory
        if (-not $apoDirectory) {
            [System.Windows.MessageBox]::Show("Előbb telepítsd az Equalizer APO-t, majd indítsd újra az appot.`n`nA pontos lépéseket a TELEPITES.txt tartalmazza.", 'Tudom, hogy meleg vagy', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not (Test-Administrator)) {
            $answer = [System.Windows.MessageBox]::Show('A beállítás mentéséhez rendszergazdai jogosultság kell. Újraindítsam az appot rendszergazdaként?', 'Tudom, hogy meleg vagy', 'YesNo', 'Question')
            if ($answer -eq 'Yes') {
                Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                $window.Close()
            }
            return
        }

        $volumePercent = [double]$VolumeSlider.Value
        $bassDb = [double]$BassSlider.Value
        $frequency = [int]$FrequencySlider.Value
        $volumeDb = if ($volumePercent -le 0) { -100.0 } else { 20.0 * [Math]::Log10($volumePercent / 100.0) }
        $maxEqGain = 0.0
        foreach ($eqSlider in $script:eqSliders) { if ([double]$eqSlider.Value -gt $maxEqGain) { $maxEqGain = [double]$eqSlider.Value } }
        if ((-not $SafetyCheck.IsChecked) -and ($volumePercent -gt 200 -or $bassDb -gt 15)) {
            $warning = [System.Windows.MessageBox]::Show('Ez a beállítás torzíthat, károsíthatja a hangszórót és a hallásodat. Biztosan alkalmazod védelem nélkül?', 'Nagyon erős beállítás', 'YesNo', 'Warning')
            if ($warning -ne 'Yes') { return }
        }
        # Reserve headroom for both the volume preamp and overlapping bass filters.
        # This prevents the harsh digital clipping heard with the previous preset.
        $profileHeadroom = if ($script:activeProfile -like 'FiveM*' -or $script:activeProfile -eq 'R6') { 0.5 } else { 0.0 }
        if (-not $SafetyCheck.IsChecked) {
            $safetyReduction = 0.0
        } elseif ($script:activeProfile -eq 'Music') {
            # Music uses gentler protection so it stays lively, while the EQ cuts
            # muddy mids and reserves enough room for bass and treble transients.
            $safetyReduction = [Math]::Min(10.0, ($bassDb * 0.40) + ($maxEqGain * 0.80) + 0.7)
        } else {
            $safetyReduction = [Math]::Min(12.0, [Math]::Max(0.0, ($bassDb * 0.40) + ($maxEqGain * 0.80) + $profileHeadroom))
        }
        $preampDb = if ($volumePercent -le 0) { -100.0 } else { $volumeDb - $safetyReduction }

        $subGain = $bassDb * 0.30
        $mainBassGain = $bassDb * 0.55
        $punchGain = $bassDb * 0.15

        $ownConfig = Join-Path $apoDirectory 'TudomHogyMelegVagy.txt'
        $mainConfig = Join-Path $apoDirectory 'config.txt'
        $backupConfig = Join-Path $apoDirectory 'config.before-TudomHogyMelegVagy.bak'
        if ((Test-Path $mainConfig) -and (-not (Test-Path $backupConfig))) { [IO.File]::Copy($mainConfig, $backupConfig, $false) }
        if (Test-Path $ownConfig) { [IO.File]::Copy($ownConfig, "$ownConfig.undo", $true) }
        $content = @(
            '# Tudom, hogy meleg vagy - managed configuration',
            ('# Volume: {0}% | Bass: {1} dB | Frequency: {2} Hz | Protection: {3}' -f [int]$volumePercent, [int]$bassDb, $frequency, $SafetyCheck.IsChecked),
            ('Preamp: {0} dB' -f $preampDb.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 1: ON LS Fc 45 Hz Gain {0} dB' -f $subGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 2: ON PK Fc {0} Hz Gain {1} dB Q 0.90' -f $frequency, $mainBassGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            ('Filter 3: ON PK Fc 115 Hz Gain {0} dB Q 1.10' -f $punchGain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)),
            'Filter 4: ON HPQ Fc 25 Hz Q 0.71'
        )
        $filterNumber = 10
        for ($i = 0; $i -lt $script:eqBands.Count; $i++) {
            $gain = [double]$script:eqSliders[$i].Value
            if ([Math]::Abs($gain) -ge 0.1) {
                $gainText = $gain.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                $content += ('Filter {0}: ON PK Fc {1} Hz Gain {2} dB Q 1.00' -f $filterNumber, $script:eqBands[$i], $gainText)
                $filterNumber++
            }
        }
        Write-LinesWithRetry $ownConfig $content

        $includeLine = 'Include: TudomHogyMelegVagy.txt'
        $mainText = if (Test-Path $mainConfig) { Read-TextWithRetry $mainConfig } else { '' }
        # Remove the include line used by older versions so effects never stack.
        $mainText = [Regex]::Replace($mainText, '(?im)^\s*Include:\s*BassForge\.txt\s*\r?\n?', '')
        if ($mainText -notmatch '(?im)^\s*Include:\s*TudomHogyMelegVagy\.txt\s*$') {
            $mainText += "`r`n# Tudom, hogy meleg vagy`r`n$includeLine`r`n"
        }
        Write-TextWithRetry $mainConfig $mainText
        $StatusText.Text = "OK - Beállítás alkalmazva: $([int]$volumePercent)% / $([int]$bassDb) dB"
        $StatusBorder.Background = '#143126'
    } catch {
        [System.Windows.MessageBox]::Show("Nem sikerült menteni:`n$($_.Exception.Message)", 'Tudom, hogy meleg vagy - hiba', 'OK', 'Error') | Out-Null
    } finally {
        $script:applyBusy = $false
    }
})

function Invoke-ApplyButton {
    $args = New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)
    $ApplyButton.RaiseEvent($args)
}

function Get-AppState {
    return [PSCustomObject]@{
        version = 3; profile = $script:activeProfile
        volume = [int]$VolumeSlider.Value; bass = [int]$BassSlider.Value; frequency = [int]$FrequencySlider.Value
        safety = [bool]$SafetyCheck.IsChecked; autoProfile = [bool]$AutoProfileCheck.IsChecked; instant = [bool]$InstantCheck.IsChecked
        eq = @($script:eqSliders | ForEach-Object { [int]$_.Value })
    }
}

function Set-AppState($state) {
    if (-not $state) { return }
    $script:activeProfile = if ($state.profile) { [string]$state.profile } else { 'Custom' }
    Set-Profile ([int]$state.volume) ([int]$state.bass) ([int]$state.frequency) ([bool]$state.safety)
    if ($state.eq -and $state.eq.Count -eq 10) { Set-EqValues ([double[]]$state.eq) }
    if ($null -ne $state.autoProfile) { $AutoProfileCheck.IsChecked = [bool]$state.autoProfile }
    if ($null -ne $state.instant) { $InstantCheck.IsChecked = [bool]$state.instant }
}

$appDataDirectory = Join-Path $env:APPDATA 'TudomHogyMelegVagy'
if (-not (Test-Path $appDataDirectory)) { [void][IO.Directory]::CreateDirectory($appDataDirectory) }
$settingsPath = Join-Path $appDataDirectory 'settings.json'
$customProfilePath = Join-Path $appDataDirectory 'custom-profile.json'

$SaveButton.Add_Click({
    (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $customProfilePath -Encoding UTF8
    $StatusText.Text = 'OK - Saját profil elmentve'
})
$LoadButton.Add_Click({
    if (Test-Path $customProfilePath) { Set-AppState (Get-Content -LiteralPath $customProfilePath -Raw | ConvertFrom-Json); $StatusText.Text = 'OK - Saját profil betöltve' }
})
$ExportButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'EQ profil (*.json)|*.json'; $dialog.FileName = 'sajat-hangprofil.json'
    if ($dialog.ShowDialog()) { (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8 }
})
$ImportButton.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'EQ profil (*.json)|*.json'
    if ($dialog.ShowDialog()) { Set-AppState (Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json) }
})
$UndoButton.Add_Click({
    $apo = Get-ApoConfigDirectory
    if ($apo) {
        $own = Join-Path $apo 'TudomHogyMelegVagy.txt'; $undo = "$own.undo"
        if (Test-Path $undo) { [IO.File]::Copy($undo, $own, $true); $StatusText.Text = 'OK - Előző alkalmazott hang visszaállítva' }
    }
})
$BypassButton.Add_Click({
    $apo = Get-ApoConfigDirectory
    if ($apo) {
        $main = Join-Path $apo 'config.txt'
        if (Test-Path $main) {
            $text = [IO.File]::ReadAllText($main)
            $text = [Regex]::Replace($text, '(?im)^\s*Include:\s*TudomHogyMelegVagy\.txt\s*\r?\n?', '')
            Write-TextWithRetry $main $text
            $StatusText.Text = 'KIKAPCSOLVA - Nyomj Alkalmazást a visszakapcsoláshoz'; $StatusBorder.Background = '#4A1F2D'
        }
    }
})
$DeviceButton.Add_Click({
    $apoConfig = Get-ApoConfigDirectory
    $installDirectory = if ($apoConfig) { Split-Path $apoConfig -Parent } else { $null }
    $candidates = @()
    if ($installDirectory) {
        $candidates += Join-Path $installDirectory 'DeviceSelector.exe'
        $candidates += Join-Path $installDirectory 'Configurator.exe'
        $candidates += @(Get-ChildItem -LiteralPath $installDirectory -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Device|Configur' } | Select-Object -ExpandProperty FullName)
    }
    $selector = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($selector) { Start-Process $selector -Verb RunAs } else { [System.Windows.MessageBox]::Show('Az Equalizer APO eszközválasztó nem található.', 'Eszközök') | Out-Null }
})

function Play-TestTone([int]$frequency = 60, [double]$seconds = 1.5) {
    $sampleRate = 44100; $samples = [int]($sampleRate * $seconds); $stream = New-Object IO.MemoryStream; $writer = New-Object IO.BinaryWriter($stream)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + $samples * 2)); $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * 2)); $writer.Write([int16]2); $writer.Write([int16]16); $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]($samples * 2))
    for ($i = 0; $i -lt $samples; $i++) { $fade = [Math]::Min(1.0, [Math]::Min($i / 2205.0, ($samples - $i) / 2205.0)); $writer.Write([int16](7000 * $fade * [Math]::Sin(2 * [Math]::PI * $frequency * $i / $sampleRate))) }
    $stream.Position = 0; $player = New-Object Media.SoundPlayer($stream); $player.PlaySync(); $writer.Dispose(); $stream.Dispose()
}
$TestButton.Add_Click({ Play-TestTone 60 1.5 })

# Debounced instant mode prevents excessive disk writes while dragging.
$instantTimer = New-Object Windows.Threading.DispatcherTimer
$instantTimer.Interval = [TimeSpan]::FromMilliseconds(550)
$instantTimer.Add_Tick({ $instantTimer.Stop(); if ($InstantCheck.IsChecked) { Invoke-ApplyButton } })
$scheduleInstant = { if ($InstantCheck.IsChecked) { $instantTimer.Stop(); $instantTimer.Start() }; Update-Labels }
$VolumeSlider.Add_ValueChanged($scheduleInstant)
$BassSlider.Add_ValueChanged($scheduleInstant)
$FrequencySlider.Add_ValueChanged($scheduleInstant)
$SafetyCheck.Add_Click({ Update-Labels; if ($InstantCheck.IsChecked) { Invoke-ApplyButton } })
foreach ($eqSlider in $script:eqSliders) { $eqSlider.Add_ValueChanged($scheduleInstant) }

# Optional automatic switching: FiveM has priority, followed by Spotify and Discord.
$script:lastAutoProfile = ''
$autoTimer = New-Object Windows.Threading.DispatcherTimer
$autoTimer.Interval = [TimeSpan]::FromSeconds(4)
$autoTimer.Add_Tick({
    if (-not $AutoProfileCheck.IsChecked) { return }
    $processNames = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName)
    $wanted = if ($processNames -match 'FiveM|FiveM_GTAProcess|GTAProcess') { 'FiveM' } elseif ($processNames -contains 'Spotify') { 'Music' } elseif ($processNames -contains 'Discord') { 'Discord' } else { '' }
    if ($wanted -and $wanted -ne $script:lastAutoProfile) {
        $script:lastAutoProfile = $wanted
        if ($wanted -eq 'FiveM') { $GameButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        elseif ($wanted -eq 'Music') { $MusicButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        elseif ($wanted -eq 'Discord') { $DiscordButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        Invoke-ApplyButton
        $StatusText.Text = "AUTO - $wanted profil aktív"
        if ($script:trayIcon) { $script:trayIcon.ShowBalloonTip(1800, 'Profilváltás', "$wanted profil bekapcsolva", [Windows.Forms.ToolTipIcon]::Info) }
    }
})
$autoTimer.Start()

# Start with Windows using a normal, removable shortcut.
$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDirectory 'TudomHogyMelegVagy.lnk'
$StartupCheck.IsChecked = Test-Path $startupShortcut
$StartupCheck.Add_Click({
    try {
        if ($StartupCheck.IsChecked) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($startupShortcut)
            $shortcut.TargetPath = $script:appLaunchPath
            $shortcut.WorkingDirectory = $script:appDirectory
            if (Test-Path $appIconPath) { $shortcut.IconLocation = "$appIconPath,0" }
            $shortcut.Save()
        } elseif (Test-Path $startupShortcut) {
            [IO.File]::Delete($startupShortcut)
        }
    } catch {
        [System.Windows.MessageBox]::Show("Indítási beállítási hiba:`n$($_.Exception.Message)", 'Hiba', 'OK', 'Error') | Out-Null
    }
})

# Remember the complete UI state between launches.
if (Test-Path $settingsPath) {
    try { Set-AppState (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json) } catch { }
}
$window.Add_Closing({
    try { (Get-AppState) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsPath -Encoding UTF8 } catch { }
})

# Display the current Windows default output and refresh it automatically.
function Update-DeviceText { $DeviceText.Text = "Aktív hangkimenet: $([AudioAppNative]::GetDefaultOutputName())" }
$deviceTimer = New-Object Windows.Threading.DispatcherTimer
$deviceTimer.Interval = [TimeSpan]::FromSeconds(5)
$deviceTimer.Add_Tick({ Update-DeviceText })
$deviceTimer.Start(); Update-DeviceText

# Global Ctrl+Alt+1..6 hotkeys. These also work while a game is focused.
$script:hotKeyButtons = @($MusicButton, $GameButton, $CombatButton, $R6Button, $DiscordButton, $MovieButton)
$script:hotKeyHook = [Windows.Interop.HwndSourceHook]{
    param([IntPtr]$hookHwnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    if ($message -eq 0x0312) {
        $index = $wParam.ToInt32() - 101
        if ($index -ge 0 -and $index -lt $script:hotKeyButtons.Count) {
            $script:hotKeyButtons[$index].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            Invoke-ApplyButton; $handled.Value = $true
        }
    }
    return [IntPtr]::Zero
}
$window.Add_SourceInitialized({
    $helper = New-Object Windows.Interop.WindowInteropHelper($window)
    $script:windowHandle = $helper.Handle
    $script:windowSource = [Windows.Interop.HwndSource]::FromHwnd($script:windowHandle)
    $script:windowSource.AddHook($script:hotKeyHook)
    for ($i = 0; $i -lt 6; $i++) { [void][AudioAppNative]::RegisterHotKey($script:windowHandle, 101 + $i, 0x0003, 0x31 + $i) }
})

# Tray icon: minimize or close to tray, double-click to restore.
$script:reallyExit = $false
$script:trayIcon = New-Object Windows.Forms.NotifyIcon
$script:trayIcon.Icon = if (Test-Path $appIconPath) { New-Object Drawing.Icon($appIconPath) } else { [Drawing.SystemIcons]::Application }
$script:trayIcon.Text = 'Tudom, hogy meleg vagy V4'
$script:trayIcon.Visible = $true
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('Megnyitás')
$showItem.Add_Click({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
[void]$trayMenu.Items.Add('-')
$trayProfiles = @(
    @('Zene - Ctrl+Alt+1', $MusicButton), @('FiveM RP - Ctrl+Alt+2', $GameButton),
    @('FiveM harc - Ctrl+Alt+3', $CombatButton), @('R6 - Ctrl+Alt+4', $R6Button),
    @('Discord - Ctrl+Alt+5', $DiscordButton), @('Film - Ctrl+Alt+6', $MovieButton)
)
foreach ($entry in $trayProfiles) {
    $profileButton = $entry[1]
    $item = $trayMenu.Items.Add([string]$entry[0])
    $item.Add_Click({ $profileButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))); Invoke-ApplyButton }.GetNewClosure())
}
[void]$trayMenu.Items.Add('-')
$exitItem = $trayMenu.Items.Add('Kilépés')
$exitItem.Add_Click({ $script:reallyExit = $true; $window.Close() })
$script:trayIcon.ContextMenuStrip = $trayMenu
$script:trayIcon.Add_DoubleClick({ $window.Show(); $window.WindowState = 'Normal'; $window.Activate() })
$window.Add_StateChanged({ if ($window.WindowState -eq 'Minimized') { $window.Hide(); $script:trayIcon.ShowBalloonTip(1200, 'Tálcán fut', 'Az app továbbra is aktív.', [Windows.Forms.ToolTipIcon]::Info) } })
$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:reallyExit) { $eventArgs.Cancel = $true; $window.Hide() }
})
$window.Add_Closed({
    for ($i = 0; $i -lt 6; $i++) { [void][AudioAppNative]::UnregisterHotKey($script:windowHandle, 101 + $i) }
    if ($script:windowSource) { $script:windowSource.RemoveHook($script:hotKeyHook) }
    $script:trayIcon.Visible = $false; $script:trayIcon.Dispose()
})

Update-Labels
$window.ShowDialog() | Out-Null
