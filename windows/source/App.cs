using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Interop;
using System.Windows.Shell;
using Microsoft.Win32;

[assembly: AssemblyTitle("F75 Studio")]
[assembly: AssemblyProduct("F75 Studio")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0")]

namespace F75Studio {
public class Studio : Window {
 const string Bg="#0D1118",Panel="#171E29",Muted="#9DAABD",Accent="#A8F0C9";
 Profile profile=new Profile(); List<KeySpec> keys; string page="light",language="pt-BR";
 Grid root; StackPanel nav; StackPanel content; TextBlock status,selection,brushLabel,applyLabel; Canvas keyboard; Dictionary<int,Button> keyButtons=new Dictionary<int,Button>(); Button applyButton;
 HashSet<int> selected=new HashSet<int>(); Dictionary<int,Button> swatchButtons=new Dictionary<int,Button>(); TextBox hex; Slider brightness; ComboBox effect,speed,effectBrightness,direction,palette,latency,sleep;
 DeviceStatusSnapshot deviceSnapshot;
 TextBlock connectionText,batteryText,deviceStatusText;
 readonly SemaphoreSlim deviceGate=new SemaphoreSlim(1,1);
 System.Windows.Threading.DispatcherTimer saveTimer,deviceChangeTimer;
 KeyboardChanges pending;
 Button retryButton;
 bool refreshing,busy,suppressSave,closeRequested,canClose,exitRequested,awaitingUsb;
 int connectionRevision;
 string lastStatus="",lastSavedSession,macroDraft="[]"; List<MacroEvent> events=new List<MacroEvent>(); ComboBox trigger; TextBox macroText,macroCapture; bool macroRecording=false; Stopwatch macroClock=new Stopwatch(); HashSet<Key> macroHeld=new HashSet<Key>(); Stack<int[]> colorUndo=new Stack<int[]>(); int activeColor=0x89F0CE; TrayIcon tray;
 // Portable build: a portable.txt next to the exe keeps the profile in a Dados folder beside it instead of %LOCALAPPDATA%.
 static string DataDir=File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"portable.txt"))?Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"Dados"):Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"F75Studio");
 static string StatePath=Path.Combine(DataDir,"session.json");
 [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window,int attribute,ref int value,int size);
 public static string ReadResource(string name){using(var r=new StreamReader(Assembly.GetExecutingAssembly().GetManifestResourceStream(name)))return r.ReadToEnd();}
 string T(string pt,string en){return language=="en"?en:pt;}
 // Frozen and shared: the UI used to allocate a new brush on every call (hundreds per page build and per repaint).
 static readonly Dictionary<string,SolidColorBrush> brushes=new Dictionary<string,SolidColorBrush>();
 static readonly Dictionary<int,SolidColorBrush> rgbBrushes=new Dictionary<int,SolidColorBrush>();
 static SolidColorBrush B(string hex){SolidColorBrush b;if(!brushes.TryGetValue(hex,out b)){b=new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));b.Freeze();brushes[hex]=b;}return b;}
 static SolidColorBrush Rgb(byte r,byte g,byte bl){int key=(r<<16)|(g<<8)|bl;SolidColorBrush b;if(!rgbBrushes.TryGetValue(key,out b)){if(rgbBrushes.Count>512)rgbBrushes.Clear();b=new SolidColorBrush(Color.FromRgb(r,g,bl));b.Freeze();rgbBrushes[key]=b;}return b;}
 public Studio(){
  Title="F75 Studio";Width=1240;Height=870;MinWidth=820;MinHeight=640;WindowStartupLocation=WindowStartupLocation.CenterScreen;WindowStyle=WindowStyle.None;ResizeMode=ResizeMode.CanResize;Background=B(Bg);Foreground=B("#EEF3FB");FontFamily=new FontFamily("Segoe UI");FontSize=14;UseLayoutRounding=true;
  Resources=(ResourceDictionary)XamlReader.Parse(ReadResource("Theme.xaml"));
  WindowChrome.SetWindowChrome(this,new WindowChrome{CaptionHeight=44,ResizeBorderThickness=new Thickness(6),CornerRadius=new CornerRadius(12),GlassFrameThickness=new Thickness(0),UseAeroCaptionButtons=false});
  Icon=BitmapFrame.Create(Assembly.GetExecutingAssembly().GetManifestResourceStream("f75.ico"));
  SourceInitialized+=(s,e)=>{try{int rounded=2;DwmSetWindowAttribute(new WindowInteropHelper(this).Handle,33,ref rounded,4);}catch{}var src=HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);if(src!=null)src.AddHook(DeviceHook);if(profile.KeepInTray && !suppressSave)SetupTray();};
  keys=Layout.Keys();
  foreach(var k in keys)profile.Colors[k.index]=0x89F0CE;
  LoadLocal();
  deviceChangeTimer=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromMilliseconds(500)};
  deviceChangeTimer.Tick+=async(s,e)=>{deviceChangeTimer.Stop();if(UiVisible)await Refresh();};
  Build();
  Loaded+=async(s,e)=>{if(!suppressSave)await Refresh();};
  Closing+=OnClosing;
  StateChanged+=async(s,e)=>{
   if(suppressSave)return;
   if(WindowState==WindowState.Minimized){
    if(tray!=null && tray.IsAvailable)HideToTray();
    else{SaveLocal();ReleaseUi();}
   }else if(root==null){
    Build();
    if(UiVisible)await Refresh();
   }
  };
 }
 void LoadLocal(){
  foreach(string path in new[]{StatePath,StatePath+".bak"}){
   if(!File.Exists(path))continue;
   try{
    KeyboardChanges loadedPending;
    var loaded=Json.ParseSession(File.ReadAllText(path),out loadedPending);
    loaded.Validate();
    profile=loaded;
    language=loaded.Language;
    pending=loadedPending;
    if(path==StatePath)lastSavedSession=Json.SerializeSession(profile,pending);
    else lastStatus=T("Cópia de segurança do perfil carregada.","Loaded the backup profile.");
    return;
   }catch(Exception ex){
    lastStatus=T("Não foi possível ler o perfil local. ","Could not read the local profile. ")+ex.Message;
   }
  }
 }
 bool UiVisible{get{return IsVisible && WindowState!=WindowState.Minimized;}}
 IntPtr DeviceHook(IntPtr hwnd,int msg,IntPtr w,IntPtr l,ref bool handled){
  // WM_DEVICECHANGE (DBT_DEVNODES_CHANGED, arrival, removal) is broadcast to top-level windows; bursts are debounced.
  if(msg==0x219){
   int code=(int)(long)w;
   if(!suppressSave && (code==7 || code==0x8000 || code==0x8004)){
    KeyboardDevice.ForgetCachedPath();
    connectionRevision++;
    if(UiVisible){deviceChangeTimer.Stop();deviceChangeTimer.Start();}
   }
  }
  return IntPtr.Zero;
 }
 // Drop controls before rebuilding a page or releasing the window.
 void ReleaseControls(){
  if(macroRecording)StopMacroRecording(false);
  root=null;nav=null;content=null;keyboard=null;status=null;selection=null;brushLabel=null;applyLabel=null;applyButton=null;retryButton=null;hex=null;brightness=null;
  connectionText=null;batteryText=null;deviceStatusText=null;macroText=null;macroCapture=null;trigger=null;effect=null;speed=null;effectBrightness=null;direction=null;palette=null;latency=null;sleep=null;
  keyButtons.Clear();swatchButtons.Clear();
 }
 void ReleaseUi(){
  deviceChangeTimer.Stop();
  if(root==null)return;
  ReleaseControls();
  Content=null;
  rgbBrushes.Clear();
  Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{if(root==null)Memory.Trim();}));
 }
 void SetupTray(){
  if(tray!=null)return;
  var handle=new WindowInteropHelper(this).Handle;
  if(handle==IntPtr.Zero)return;
  tray=new TrayIcon(handle,"F75 Studio");
  tray.DoubleClick+=RestoreWindow;
  tray.MenuItems=()=>new List<KeyValuePair<string,Action>>{
   new KeyValuePair<string,Action>(T("Abrir F75 Studio","Open F75 Studio"),RestoreWindow),
   new KeyValuePair<string,Action>(T("Desligar RGB das teclas","Turn key RGB off"),()=>ToggleRgb(true)),
   new KeyValuePair<string,Action>(T("Restaurar minhas cores","Restore my colors"),()=>ToggleRgb(false)),
   new KeyValuePair<string,Action>(null,null),
   new KeyValuePair<string,Action>(T("Sair do F75 Studio","Quit F75 Studio"),()=>{exitRequested=true;Close();})};
 }
 void RemoveTray(){if(tray!=null){tray.Dispose();tray=null;}}
 void HideToTray(){
  SaveLocal();
  Hide();
  ReleaseUi();
 }
 void MinimizeWindow(){
  if(tray!=null && tray.IsAvailable)HideToTray();
  else WindowState=WindowState.Minimized;
 }
 void RestoreWindow(){
  bool needsRefresh=UiVisible;
  if(!IsVisible)Show();
  if(WindowState==WindowState.Minimized)WindowState=WindowState.Normal;
  if(root==null){Build();needsRefresh=true;}
  Activate();
  if(needsRefresh){var ignored=Refresh();}
 }
 async void OnClosing(object sender,System.ComponentModel.CancelEventArgs e){
  if(canClose || suppressSave){deviceChangeTimer.Stop();if(!suppressSave)SaveLocal();RemoveTray();return;}
  if(busy || closeRequested){
   e.Cancel=true;
   exitRequested=false;
   SetStatus(T("Aguarde a operação USB terminar.","Wait for the USB operation to finish."));
   return;
  }
  if(profile.KeepInTray && tray!=null && tray.IsAvailable && !exitRequested){
   e.Cancel=true;
   HideToTray();
   return;
  }
  e.Cancel=true;
  closeRequested=true;
  exitRequested=false;
  bool saved=SaveLocal();
  if(saved && pending!=KeyboardChanges.None){
   await Execute(()=>SendPending(pending),false);
   saved=SaveLocal();
  }
  if(!saved || pending!=KeyboardChanges.None){
   string prompt=saved
    ? T("As alterações ficaram pendentes neste computador. Sair agora?","Changes are pending on this PC. Quit now?")
    : T("O perfil local não pôde ser salvo. Sair mesmo assim?","The local profile could not be saved. Quit anyway?");
   if(MessageBox.Show(lastStatus+"\n\n"+prompt,"F75 Studio",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)!=MessageBoxResult.Yes){
    closeRequested=false;
    RestoreWindow();
    return;
   }
  }
  // A close with no USB operation can finish before WPF returns from the Closing event.
  var closing=Dispatcher.BeginInvoke(new Action(()=>{canClose=true;Close();}));
 }
 TextBlock Text(string text,double size=14,string color=null){return new TextBlock {Text=text,FontSize=size,Foreground=B(color??"#EEF3FB"),TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,10)};}
 Button Btn(string label,Action action,bool primary=false){var b=new Button {Content=label,Margin=new Thickness(0,0,8,8),Padding=new Thickness(13,8,13,8)};if(primary){b.Background=B(Accent);b.Foreground=B(Bg);}b.Click+=(s,e)=>{try{action();}catch(Exception ex){ReportError(ex);}};return b;}
 StackPanel Card(string title,string desc=null){var stack=new StackPanel();stack.Children.Add(Text(title,19));if(desc!=null)stack.Children.Add(Text(desc,13,Muted));var border=new Border {Background=B(Panel),BorderBrush=B("#293547"),BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(9),Padding=new Thickness(18,15,18,10),Margin=new Thickness(0,0,0,12),Child=stack};content.Children.Add(border);return stack;}
 void Row(StackPanel parent,params UIElement[] items){var w=new WrapPanel();foreach(var i in items)w.Children.Add(i);parent.Children.Add(w);}
 ComboBox Combo(IEnumerable<string> values,int index=0,int width=190){var c=new ComboBox{Width=width,Margin=new Thickness(0,0,12,12),Padding=new Thickness(10,8,10,8)};foreach(var x in values)c.Items.Add(x);c.SelectedIndex=index;return c;}
 StackPanel Field(string label,UIElement c){var p=new StackPanel {Margin=new Thickness(0,5,8,0)};p.Children.Add(Text(label,12,Muted));p.Children.Add(c);return p;}
 void Build(){
  ReleaseControls();
  root=new Grid{Background=B(Bg)};root.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(215)});root.ColumnDefinitions.Add(new ColumnDefinition());root.RowDefinitions.Add(new RowDefinition{Height=new GridLength(44)});root.RowDefinitions.Add(new RowDefinition());root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});root.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});Content=root;
  var titlebar=new Grid{Background=B("#141D29")};Grid.SetColumnSpan(titlebar,2);root.Children.Add(titlebar);titlebar.ColumnDefinitions.Add(new ColumnDefinition());titlebar.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
  var titleText=Text("F75 Studio",14,"#EAF0FA");titleText.Margin=new Thickness(18,0,0,0);titleText.VerticalAlignment=VerticalAlignment.Center;titlebar.Children.Add(titleText);
  var controls=new StackPanel{Orientation=Orientation.Horizontal};Grid.SetColumn(controls,1);titlebar.Children.Add(controls);
  var minimize=Btn("—",MinimizeWindow);minimize.Width=47;minimize.Margin=new Thickness(0);minimize.Padding=new Thickness(0);minimize.Background=B("#141D29");WindowChrome.SetIsHitTestVisibleInChrome(minimize,true);controls.Children.Add(minimize);
  var maximize=Btn("□",()=>{WindowState=WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized;});maximize.Width=47;maximize.Margin=new Thickness(0);maximize.Padding=new Thickness(0);maximize.Background=B("#141D29");WindowChrome.SetIsHitTestVisibleInChrome(maximize,true);controls.Children.Add(maximize);
  var exit=Btn("×",()=>Close());exit.Width=50;exit.Margin=new Thickness(0);exit.Padding=new Thickness(0);exit.Background=B("#41232D");WindowChrome.SetIsHitTestVisibleInChrome(exit,true);controls.Children.Add(exit);
  var sidebar=new Border{Background=B("#101723"),BorderBrush=B("#283445"),BorderThickness=new Thickness(0,0,1,0),Padding=new Thickness(20,25,14,18)};Grid.SetRow(sidebar,1);Grid.SetRowSpan(sidebar,3);root.Children.Add(sidebar);nav=new StackPanel();sidebar.Child=nav;
  var model=Text("FREE WOLF F75",16);
  model.FontWeight=FontWeights.SemiBold;
  model.Margin=new Thickness(5,0,0,16);
  nav.Children.Add(model);
  string[] ids={"light","effects","performance","macros","profiles","device"};string[] labels={T("Cores por tecla","Per-key colors"),T("Efeitos RGB","RGB effects"),T("Desempenho","Performance"),"Macros",T("Perfis","Profiles"),T("Dispositivo","Device")};
  for(int i=0;i<ids.Length;i++){
   string id=ids[i];
   var b=Btn(labels[i],()=>{if(page!=id){page=id;Build();}});
   b.HorizontalContentAlignment=HorizontalAlignment.Left;
   b.Margin=new Thickness(0,0,0,3);
   b.Padding=new Thickness(11,9,8,9);
   b.BorderBrush=Brushes.Transparent;
   b.Background=B(page==id?"#22372F":"#101723");
   if(page==id){
    b.Foreground=B(Accent);
    b.FontWeight=FontWeights.SemiBold;
   }
   nav.Children.Add(b);
  }
  nav.Children.Add(new Border{Height=30});nav.Children.Add(Text(T("IDIOMA","LANGUAGE"),11,Muted));var languages=Combo(new[]{"Português (Brasil)","English"},language=="en"?1:0,164);languages.SelectionChanged+=(s,e)=>{language=languages.SelectedIndex==1?"en":"pt-BR";profile.Language=language;SaveLocal();Build();};nav.Children.Add(languages);
  nav.Children.Add(new Border{Height=15});
  connectionText=Text("",12,Accent);
  batteryText=Text("",12,Muted);
  nav.Children.Add(connectionText);
  nav.Children.Add(batteryText);
  UpdateDeviceLabels();
  var scroll=new ScrollViewer{VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Grid.SetColumn(scroll,1);Grid.SetRow(scroll,1);root.Children.Add(scroll);content=new StackPanel{Margin=new Thickness(22,19,22,8)};scroll.Content=content;
  var heading=Text(labels[Array.IndexOf(ids,page)],26);
  heading.FontWeight=FontWeights.SemiBold;
  heading.Margin=new Thickness(0,0,0,13);
  content.Children.Add(heading);
  if(page=="light")Lighting();else if(page=="effects")Effects();else if(page=="performance")Performance();else if(page=="macros")Macros();else if(page=="profiles")Profiles();else Device();
  var command=new Border{Background=B("#172621"),BorderBrush=B("#355446"),BorderThickness=new Thickness(0,1,0,0),Padding=new Thickness(24,10,20,8),Visibility=page=="light"?Visibility.Visible:Visibility.Collapsed};Grid.SetColumn(command,1);Grid.SetRow(command,2);root.Children.Add(command);var commandGrid=new Grid();commandGrid.ColumnDefinitions.Add(new ColumnDefinition());commandGrid.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});command.Child=commandGrid;applyLabel=Text("",13,"#DBF6E7");applyLabel.VerticalAlignment=VerticalAlignment.Center;applyLabel.Margin=new Thickness(0);commandGrid.Children.Add(applyLabel);applyButton=Btn(T("Aplicar cores","Apply colors"),ApplyColors,true);applyButton.Margin=new Thickness(8,0,0,0);Grid.SetColumn(applyButton,1);commandGrid.Children.Add(applyButton);UpdateApply();
  var footer=new Border{Background=B("#121922"),BorderBrush=B("#293547"),BorderThickness=new Thickness(0,1,0,0),Padding=new Thickness(20,8,16,8)};
  Grid.SetColumn(footer,1);
  Grid.SetRow(footer,3);
  root.Children.Add(footer);
  var footerGrid=new Grid();
  footerGrid.ColumnDefinitions.Add(new ColumnDefinition());
  footerGrid.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
  footer.Child=footerGrid;
  status=Text(lastStatus==""?ConnectionGuidance():lastStatus,13,Muted);
  status.Margin=new Thickness(0,4,8,4);
  status.VerticalAlignment=VerticalAlignment.Center;
  footerGrid.Children.Add(status);
  retryButton=Btn(T("Enviar pendências","Send pending settings"),()=>ApplySettings(pending));
  retryButton.Margin=new Thickness(6,0,0,0);
  Grid.SetColumn(retryButton,1);
  footerGrid.Children.Add(retryButton);
  nav.IsEnabled=!busy;
  content.IsEnabled=!busy;
  applyButton.IsEnabled=!busy;
  UpdateApply();
 }
 void Lighting(){
  var guide=Card(T("Paleta","Palette"));
  var colors=new[]{0xA8F0C9,0x5BC8FF,0x8878F8,0xFF77AB,0xFF985C,0xFFD46A,0xF8FBFF,0x000000};
  var swatches=new WrapPanel{Margin=new Thickness(0,2,0,10)};swatchButtons.Clear();
  foreach(int color in colors){var swatch=new Button{Width=43,Height=43,Background=Rgb((byte)(color>>16),(byte)(color>>8),(byte)color),BorderBrush=B(color==activeColor?"#FFFFFF":"#405064"),BorderThickness=new Thickness(color==activeColor?4:2),Margin=new Thickness(0,0,9,8),ToolTip="#"+color.ToString("X6"),Padding=new Thickness(0)};swatch.Click+=(s,e)=>ChooseColor(color);swatches.Children.Add(swatch);swatchButtons[color]=swatch;}guide.Children.Add(swatches);
  hex=new TextBox{Text="#"+activeColor.ToString("X6"),Width=126,Margin=new Thickness(0,0,9,8),Padding=new Thickness(12,10,12,10),FontFamily=new FontFamily("Consolas")};hex.KeyDown+=(s,e)=>{if(e.Key==Key.Enter){int color;if(TryColor(out color)){ChooseColor(color);Keyboard.ClearFocus();}e.Handled=true;}};hex.LostKeyboardFocus+=(s,e)=>{int color;if(TryColor(out color))ChooseColor(color);};
  brushLabel=Text("",13,Accent);brushLabel.VerticalAlignment=VerticalAlignment.Center;Row(guide,hex,Btn(T("Mais cores…","More colors…"),()=>{int picked=ColorPicker.Pick(new WindowInteropHelper(this).Handle,activeColor);if(picked>=0)ChooseColor(picked);}),brushLabel);UpdateBrush();
  var c=Card(T("Prévia","Preview"),T("Ctrl + clique seleciona várias teclas.","Ctrl + click selects multiple keys."));
  keyboard=new Canvas{Width=600,Height=267,Background=B("#101722")};keyButtons.Clear();
  foreach(var k in keys){var button=new Button{Content=k.name,Width=k.rect[2],Height=k.rect[3],FontSize=k.name.Length>5?7:9,Padding=new Thickness(0),Margin=new Thickness(0),Tag=k.index,ToolTip=k.name};Canvas.SetLeft(button,k.rect[0]);Canvas.SetTop(button,k.rect[1]);button.Click+=(s,e)=>{if((Keyboard.Modifiers&ModifierKeys.Control)!=0){if(!selected.Add(k.index))selected.Remove(k.index);Repaint();return;}int color;if(!TryColor(out color))return;RememberColors();profile.Colors[k.index]=color;selected.Clear();Changed();};keyboard.Children.Add(button);keyButtons[k.index]=button;}
  var bar=new Border{Width=7,Height=125,CornerRadius=new CornerRadius(3),Background=B("#BDC8D2"),ToolTip=T("Indicador lateral: controle independente desconhecido","Side indicator: independent control unknown")};Canvas.SetLeft(bar,531);Canvas.SetTop(bar,70);keyboard.Children.Add(bar);
  var knob=new Border{Width=39,Height=39,CornerRadius=new CornerRadius(22),Background=B("#343D48"),BorderBrush=B("#526172"),BorderThickness=new Thickness(3)};Canvas.SetLeft(knob,539);Canvas.SetTop(knob,20);keyboard.Children.Add(knob);
  c.Children.Add(new Viewbox{Stretch=Stretch.Uniform,Child=keyboard,MaxHeight=330,Margin=new Thickness(0,8,0,15)});selection=Text("",12,Muted);c.Children.Add(selection);
  Row(c,Btn(T("Pintar seleção","Paint selected"),()=>Paint(false),true),Btn(T("Pintar todas","Paint all"),()=>Paint(true)),Btn(T("Desfazer","Undo"),UndoColors),Btn(T("Limpar todas","Clear all"),()=>{RememberColors();foreach(var k in keys)profile.Colors[k.index]=0;selected.Clear();Changed();}));
  var presets=Card(T("Estilos","Styles"));Row(presets,Btn("Mint",()=>Preset(0)),Btn("Sunset",()=>Preset(1)),Btn("Aurora",()=>Preset(2)),Btn("WASD",()=>Preset(3)));
  var settings=Card(T("Brilho","Brightness"));
  brightness=new Slider{Minimum=0,Maximum=100,Value=profile.Brightness,TickFrequency=1,IsSnapToTickEnabled=true,Width=260,Margin=new Thickness(0,6,14,12)};var value=Text(profile.Brightness+"%",16,Accent);brightness.ValueChanged+=(s,e)=>{if(profile.Brightness==(int)brightness.Value)return;profile.Brightness=(int)brightness.Value;value.Text=profile.Brightness+"%";Changed();};Row(settings,brightness,value);
  Repaint();
 }
 void Effects(){
  var ecard=Card(T("Efeitos do teclado","Keyboard effects"),T("Escolha uma animação do firmware e envie ao F75.","Choose a firmware animation and send it to the F75."));
  string[] pt={"Ondas horizontais","Estrelas","Ondas verticais","Expansão dupla","Ciclo de cores","Caleidoscópio","Estático","Respiração","Cruzamento","Aurora","Respiração por tecla","Panorama","Serpente","Tornado","Três acima / abaixo","Chuva","Catavento","Senoidal","Cavalgada","Entrelaçado","Ritmo de música (experimental)","Ritmo de tela (experimental)"};
  string[] en={"Horizontal ripples","Stars","Vertical ripples","Double expansion","Spectrum cycle","Kaleidoscope","Static","Breathing","Crossing","Aurora","Per-key breathing","Panorama","Snake","Tornado","Top / bottom three","Rain","Windmill","Sine wave","Gallop","Crisscross","Music rhythm (experimental)","Screen rhythm (experimental)"};
  int[] effectModes=Enumerable.Range(1,20).Concat(new[]{22,23}).ToArray();
  effect=Combo(language=="en"?en:pt,Array.IndexOf(effectModes,profile.EffectMode),280);effectBrightness=Combo(new[]{"1","2","3","4","5"},profile.EffectBrightness-1,80);speed=Combo(new[]{"1","2","3","4","5"},profile.EffectSpeed-1,80);direction=Combo(new[]{"0","1","2","3"},profile.EffectDirection,80);palette=Combo(language=="en"?new[]{"Rainbow","Red","Orange","Yellow","Green","Cyan","Blue","Purple","White"}:new[]{"Arco-íris","Vermelho","Laranja","Amarelo","Verde","Ciano","Azul","Roxo","Branco"},profile.EffectPalette,150);
  Row(ecard,Field(T("Efeito","Effect"),effect),Field(T("Brilho","Brightness"),effectBrightness),Field(T("Velocidade","Speed"),speed),Field(T("Direção","Direction"),direction),Field(T("Paleta","Palette"),palette));
  ecard.Children.Add(Text(T("Os modos 22 e 23 constam no layout do driver original, mas podem depender do módulo de áudio/tela dele. No F75 Studio, ficam em modo experimental.","Modes 22 and 23 are listed in the original driver layout, but may depend on its audio/screen module. They are experimental in F75 Studio."),12,Muted));
  ecard.Children.Add(Text(T("Alguns efeitos usam cores ou direção próprias. Volte a Cores por tecla para aplicar seu desenho personalizado.","Some effects use their own colors or direction. Return to Per-key colors to apply your custom layout."),12,Muted));
  Row(ecard,Btn(T("Aplicar efeito","Apply effect"),()=>{
   profile.EffectMode=effectModes[effect.SelectedIndex];
   profile.EffectBrightness=effectBrightness.SelectedIndex+1;
   profile.EffectSpeed=speed.SelectedIndex+1;
   profile.EffectDirection=direction.SelectedIndex;
   profile.EffectPalette=palette.SelectedIndex;
   profile.LightMode=1;
   ApplySettings(KeyboardChanges.Lighting);
  },true));
  Row(ecard,Btn(T("Desligar RGB das teclas","Turn key RGB off"),()=>ToggleRgb(true)),Btn(T("Restaurar minhas cores","Restore my colors"),()=>ToggleRgb(false)));
  var note=Card(T("Luz da barra lateral","Side light bar"));note.Children.Add(Text(T("O driver não inclui essa barra no mapa RGB por tecla e não foi encontrado comando separado para desligá-la. Portanto, o botão Limpar todas apaga as teclas RGB, mas pode não apagar a barra.","The driver does not include this bar in the per-key RGB map, and no separate off command was found. Clear all turns off key RGB, but may leave the bar on."),13,Muted));
  note.Children.Add(Text(T("Tentativa manual não confirmada para este modelo: pressione Fn + Shift esquerdo para alternar o efeito da barra. Esse atalho aparece em manuais de outras variantes F75; se não mudar nada, não insista nem use combinações de reset.","Unconfirmed manual attempt for this model: press Fn + Left Shift to toggle the strip effect. This shortcut appears in manuals for other F75 variants; if nothing changes, do not keep trying or use reset combinations."),13,Muted));

 }
 void Repaint(){if(keyboard==null)return;foreach(var k in keys){Button b;if(!keyButtons.TryGetValue(k.index,out b))continue;int v=profile.Colors[k.index];byte r=(byte)(((v>>16)&255)*profile.Brightness/100),g=(byte)(((v>>8)&255)*profile.Brightness/100),bl=(byte)((v&255)*profile.Brightness/100);bool unlit=v==0 || profile.Brightness==0;b.Background=unlit?B("#232D3A"):Rgb(r,g,bl);int luminance=(r*299+g*587+bl*114)/1000;b.Foreground=B(unlit || luminance<145?"#F3F7FC":"#10202A");b.BorderBrush=selected.Contains(k.index)?B("#FFFFFF"):B("#465468");b.BorderThickness=new Thickness(selected.Contains(k.index)?3:1);}if(selection!=null)selection.Text=selected.Count>0?selected.Count+T(" tecla(s) marcadas • use Pintar seleção"," key(s) selected • use Paint selected"):T("Clique numa tecla para pintá-la com a cor escolhida.","Click a key to paint it with the chosen color.");UpdateApply();}
 void UpdateApply(){
  if(retryButton!=null){
   retryButton.Visibility=pending==KeyboardChanges.None?Visibility.Collapsed:Visibility.Visible;
   retryButton.IsEnabled=!busy;
  }
  if(applyLabel==null)return;
  applyLabel.Text=(pending & KeyboardChanges.Lighting)!=0
   ? T("Iluminação pendente no teclado.","Lighting pending on the keyboard.")
   : profile.LightMode==2?T("RGB das teclas desligado.","Key RGB off.")
   : profile.LightMode==1?T("Modo de efeito selecionado.","Effect mode selected."):"";
 }
 void UpdateBrush(){if(brushLabel!=null)brushLabel.Text=T("Pincel ativo: ","Active brush: ")+"#"+activeColor.ToString("X6");foreach(var pair in swatchButtons){bool active=pair.Key==activeColor;pair.Value.BorderBrush=B(active?"#FFFFFF":"#405064");pair.Value.BorderThickness=new Thickness(active?4:2);}}
 void ChooseColor(int color){activeColor=color;if(hex!=null)hex.Text="#"+color.ToString("X6");UpdateBrush();}
 bool TryColor(out int color){color=0;if(hex==null)return false;string s=hex.Text.Trim().TrimStart('#');if(s.Length==6 && Int32.TryParse(s,NumberStyles.HexNumber,CultureInfo.InvariantCulture,out color)){activeColor=color;UpdateBrush();return true;}SetStatus(T("Cor inválida. Use #RRGGBB.","Invalid color. Use #RRGGBB."));return false;}
 void RememberColors(){colorUndo.Push((int[])profile.Colors.Clone());if(colorUndo.Count>30){var recent=colorUndo.ToArray().Take(30).Reverse().ToArray();colorUndo=new Stack<int[]>(recent);}}
 void UndoColors(){if(colorUndo.Count==0){SetStatus(T("Nada para desfazer.","Nothing to undo."));return;}profile.Colors=colorUndo.Pop();Changed();}
 void Changed(){
  profile.LightMode=0;
  pending|=KeyboardChanges.Lighting;
  Repaint();
  ScheduleSave();
 }
 void Paint(bool all){int color;if(!TryColor(out color))return;if(!all && selected.Count==0){SetStatus(T("Marque teclas com Ctrl + clique.","Select keys with Ctrl + click."));return;}RememberColors();foreach(int i in all?keys.Select(k=>k.index):selected)profile.Colors[i]=color;selected.Clear();Changed();}
 void Preset(int p){RememberColors();foreach(var k in keys){double t=Math.Max(0,Math.Min(1,k.rect[0]/580.0));int a=p==1?0xff785c:p==2?0x64efcf:0x89f0ce,b=p==1?0x985cf9:p==2?0x8f70ff:0x89f0ce;int r=(int)(((a>>16)&255)*(1-t)+((b>>16)&255)*t),g=(int)(((a>>8)&255)*(1-t)+((b>>8)&255)*t),bl=(int)((a&255)*(1-t)+(b&255)*t);profile.Colors[k.index]=p==3?(new[]{"W","A","S","D"}.Contains(k.name)?0x89f0ce:0x232b38):(r<<16)|(g<<8)|bl;}Changed();}
 void ApplyColors(){
  profile.LightMode=0;
  ApplySettings(KeyboardChanges.Lighting);
 }
 void Performance(){
  var quick=Card(T("Modo baixa latência","Low latency"),T("Seleciona a resposta mais rápida do firmware e desativa a suspensão.","Selects the fastest firmware response and disables sleep."));
  Row(quick,Btn(T("Ativar baixa latência","Enable low latency"),()=>{
   profile.Response=1;
   profile.Sleep=4;
   latency.SelectedIndex=0;
   sleep.SelectedIndex=3;
   ApplySettings(KeyboardChanges.Performance);
  },true));

  var c=Card(T("Resposta e suspensão","Response and sleep"),T("Se uma tecla registrar dois toques, experimente um nível de resposta mais alto.","If a key registers twice, try a higher response setting."));
  latency=Combo(new[]{T("1 · Menor atraso","1 · Lowest delay"),T("2 · Equilibrado","2 · Balanced"),T("3 · Mais filtragem","3 · More filtering")},profile.Response-1,220);
  sleep=Combo(new[]{T("2 minutos","2 minutes"),T("15 minutos","15 minutes"),T("30 minutos","30 minutes"),T("Não suspender","Never sleep")},profile.Sleep-1,190);
  var responseField=Field(T("Resposta das teclas","Key response"),latency);
  var sleepField=Field(T("Tempo de inatividade","Inactivity timeout"),sleep);
  Row(responseField,Btn(T("Aplicar resposta","Apply response"),()=>{
   profile.Response=latency.SelectedIndex+1;
   ApplySettings(KeyboardChanges.Response);
  }));
  Row(sleepField,Btn(T("Aplicar suspensão","Apply sleep"),()=>{
   profile.Sleep=sleep.SelectedIndex+1;
   ApplySettings(KeyboardChanges.Sleep);
  }));
  Row(c,responseField,sleepField);

  var test=Card(T("Teste de digitação","Typing test"),T("Digite algumas palavras para conferir se há caracteres repetidos.","Type a few words to check for repeated characters."));
  test.Children.Add(new TextBox{Height=90,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,Padding=new Thickness(10)});
 }
 void Macros(){
  var c=Card(T("Sequências no teclado · experimental","On-keyboard sequences · experimental"),T("Formato identificado no executável original; execução física ainda não validada. Até 60 eventos, com soltura de todas as teclas. Use uma tecla secundária para experimentar.","Format identified in the original executable; physical execution is not yet validated. Up to 60 events, with all keys released. Use a secondary key to try it."));
  var targets=keys.Where(k=>k.name!="Fn").ToList();trigger=Combo(targets.Select(k=>k.name+" · "+k.index),targets.FindIndex(k=>k.name=="End"),250);c.Children.Add(Field(T("Tecla de acionamento · camada principal","Trigger key · main layer"),trigger));
  var preset=Combo(new[]{T("Copiar (Ctrl+C)","Copy (Ctrl+C)"),T("Colar (Ctrl+V)","Paste (Ctrl+V)"),T("Salvar (Ctrl+S)","Save (Ctrl+S)"),T("Desfazer (Ctrl+Z)","Undo (Ctrl+Z)")},0,250);
  Row(c,preset,Btn(T("Carregar sequência","Load sequence"),()=>{int[] codes={6,25,22,29};events=new List<MacroEvent>{new MacroEvent{Code=224,Delay=10},new MacroEvent{Code=codes[preset.SelectedIndex],Delay=20},new MacroEvent{Code=codes[preset.SelectedIndex],Release=true,Delay=10},new MacroEvent{Code=224,Release=true,Delay=10}};macroText.Text=Json.Serialize(events);}));
  c.Children.Add(Text(T("Gravar uma sequência","Record a sequence"),15));
  macroCapture=new TextBox{Text=T("Clique em Iniciar gravação e digite aqui…","Click Start recording and type here…"),Height=55,IsReadOnly=true,Focusable=true,Padding=new Thickness(14),Margin=new Thickness(0,0,0,10),Background=B("#11161F"),BorderBrush=B("#3B4658")};
  macroCapture.PreviewKeyDown+=(s,e)=>{if(!macroRecording)return;Key k=e.Key==Key.System?e.SystemKey:e.Key;int code=HidUsage(k);if(code>0 && !macroHeld.Contains(k) && events.Count+macroHeld.Count+2<=60){macroHeld.Add(k);events.Add(new MacroEvent{Code=code,Delay=(int)Math.Max(10,Math.Min(31000,macroClock.ElapsedMilliseconds))});macroClock.Restart();macroText.Text=Json.Serialize(events);}e.Handled=true;};
  macroCapture.PreviewKeyUp+=(s,e)=>{if(!macroRecording)return;Key k=e.Key==Key.System?e.SystemKey:e.Key;int code=HidUsage(k);if(code>0 && macroHeld.Remove(k) && events.Count<60){events.Add(new MacroEvent{Code=code,Release=true,Delay=(int)Math.Max(10,Math.Min(31000,macroClock.ElapsedMilliseconds))});macroClock.Restart();macroText.Text=Json.Serialize(events);}e.Handled=true;};
  Row(c,Btn(T("Iniciar gravação","Start recording"),StartMacroRecording,true),Btn(T("Parar gravação","Stop recording"),()=>StopMacroRecording(true)));
  c.Children.Add(macroCapture);
  c.Children.Add(Text(T("Editor de eventos: Code = uso USB HID; Release = soltar; Delay = intervalo em ms (quantizado pelo firmware).","Event editor: Code = USB HID usage; Release = key up; Delay = interval in ms (quantized by firmware)."),13,Muted));
  macroText=new TextBox{Text=macroDraft,Height=160,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Padding=new Thickness(12),FontFamily=new FontFamily("Consolas")};
  macroText.TextChanged+=(s,e)=>macroDraft=((TextBox)s).Text;
  macroCapture.LostKeyboardFocus+=(s,e)=>StopMacroRecording(false);
  c.Children.Add(macroText);
  c.Children.Add(Text(T("Enviar substitui a função da tecla escolhida na camada principal. Restaure a função padrão no botão abaixo.","Sending replaces the selected key's main-layer function. Restore its default function using the button below."),13,Muted));
  Row(c,Btn(T("Enviar macro experimental","Send experimental macro"),()=>{try{events=Json.ParseMacro(macroText.Text);if(events==null)throw new InvalidDataException();var packets=Protocol.Macro(targets[trigger.SelectedIndex].index,events);Run(()=>SendPackets(packets));}catch(Exception ex){SetStatus(T("Macro inválida: ","Invalid macro: ")+ex.Message);}}),Btn(T("Restaurar esta tecla","Restore this key"),()=>{var packet=Protocol.Packet(4,1,(byte)targets[trigger.SelectedIndex].index,0);Run(()=>SendPackets(new[]{packet}));}));
 }
 void StartMacroRecording(){events.Clear();macroHeld.Clear();macroText.Text="[]";macroRecording=true;macroClock.Restart();if(macroCapture!=null){macroCapture.Text=T("GRAVANDO — pressione e solte as teclas nesta área","RECORDING — press and release keys in this area");macroCapture.Focus();}SetStatus(T("Gravando até 60 eventos. As teclas são capturadas somente nesta caixa.","Recording up to 60 events. Keys are captured only in this box."));}
 void StopMacroRecording(bool report){if(!macroRecording)return;macroRecording=false;foreach(Key k in macroHeld.ToArray()){int code=HidUsage(k);if(code>0 && events.Count<60)events.Add(new MacroEvent{Code=code,Release=true,Delay=10});}macroHeld.Clear();if(macroClock.IsRunning)macroClock.Stop();if(macroText!=null)macroText.Text=events.Count==0?"[]":Json.Serialize(events);if(macroCapture!=null)macroCapture.Text=T("Gravação parada · ","Recording stopped · ")+events.Count+T(" eventos"," events");if(report)SetStatus(T("Sequência gravada. Confira os eventos e envie para testar.","Sequence recorded. Review the events and send it to test."));}
 static int HidUsage(Key key){int vk=KeyInterop.VirtualKeyFromKey(key);if(vk>=0x41&&vk<=0x5a)return 4+vk-0x41;if(vk>=0x31&&vk<=0x39)return 30+vk-0x31;if(vk==0x30)return 39;switch(key){case Key.Return:return 40;case Key.Escape:return 41;case Key.Back:return 42;case Key.Tab:return 43;case Key.Space:return 44;case Key.OemMinus:return 45;case Key.OemPlus:return 46;case Key.OemOpenBrackets:return 47;case Key.OemCloseBrackets:return 48;case Key.Oem5:return 49;case Key.Oem1:return 51;case Key.OemQuotes:return 52;case Key.Oem3:return 53;case Key.OemComma:return 54;case Key.OemPeriod:return 55;case Key.OemQuestion:return 56;case Key.CapsLock:return 57;case Key.F1:return 58;case Key.F2:return 59;case Key.F3:return 60;case Key.F4:return 61;case Key.F5:return 62;case Key.F6:return 63;case Key.F7:return 64;case Key.F8:return 65;case Key.F9:return 66;case Key.F10:return 67;case Key.F11:return 68;case Key.F12:return 69;case Key.PrintScreen:return 70;case Key.Scroll:return 71;case Key.Pause:return 72;case Key.Insert:return 73;case Key.Home:return 74;case Key.PageUp:return 75;case Key.Delete:return 76;case Key.End:return 77;case Key.PageDown:return 78;case Key.Right:return 79;case Key.Left:return 80;case Key.Down:return 81;case Key.Up:return 82;case Key.NumLock:return 83;case Key.Divide:return 84;case Key.Multiply:return 85;case Key.Subtract:return 86;case Key.Add:return 87;case Key.NumPad1:return 89;case Key.NumPad2:return 90;case Key.NumPad3:return 91;case Key.NumPad4:return 92;case Key.NumPad5:return 93;case Key.NumPad6:return 94;case Key.NumPad7:return 95;case Key.NumPad8:return 96;case Key.NumPad9:return 97;case Key.NumPad0:return 98;case Key.Decimal:return 99;case Key.Oem102:return 100;case Key.Apps:return 101;case Key.AbntC1:return 135;case Key.LeftCtrl:return 224;case Key.LeftShift:return 225;case Key.LeftAlt:return 226;case Key.LWin:return 227;case Key.RightCtrl:return 228;case Key.RightShift:return 229;case Key.RightAlt:return 230;case Key.RWin:return 231;default:return 0;}}
 void Profiles(){
  var c=Card(T("Seus perfis","Your profiles"),T("Cores e preferências salvas em JSON no computador. Importar carrega a prévia; nada é enviado automaticamente.","Colors and preferences saved as JSON on your computer. Import loads the preview; nothing is sent automatically."));
  var name=new TextBox{Text=profile.Name,MaxLength=80,Padding=new Thickness(12),Margin=new Thickness(0,0,0,15)};name.TextChanged+=(s,e)=>{if(!String.IsNullOrWhiteSpace(name.Text)){profile.Name=name.Text;ScheduleSave();}};c.Children.Add(name);
  Row(c,Btn(T("Exportar perfil","Export profile"),()=>{var d=new SaveFileDialog{Filter="F75 profile (*.json)|*.json",FileName="F75-profile.json"};if(d.ShowDialog()==true)try{profile.Validate();File.WriteAllText(d.FileName,Json.Serialize(profile),Encoding.UTF8);SetStatus(T("Perfil exportado.","Profile exported."));}catch(Exception ex){SetStatus(ex.Message);}},true),Btn(T("Importar perfil","Import profile"),()=>{var d=new OpenFileDialog{Filter="F75 profile (*.json)|*.json"};if(d.ShowDialog()==true)try{if(new FileInfo(d.FileName).Length>131072)throw new InvalidDataException("File too large");var p=Json.ParseProfile(File.ReadAllText(d.FileName));p.Validate();p.KeepInTray=profile.KeepInTray;profile=p;language=p.Language;pending=KeyboardChanges.All;colorUndo.Clear();selected.Clear();Build();if(SaveLocal())SetStatus(T("Perfil importado. Envie os ajustes pelo cabo USB.","Profile imported. Send the settings over USB."));}catch(Exception ex){SetStatus(T("Não foi possível importar: ","Could not import: ")+ex.Message);}}));
  Row(c,Btn(T("Aplicar perfil no teclado","Apply profile to keyboard"),()=>ApplySettings(KeyboardChanges.All),true));
 }
 void ToggleRgb(bool off){
  if(busy || closeRequested)return;
  profile.LightMode=off?2:0;
  ApplySettings(KeyboardChanges.Lighting);
 }
 void Device(){
  var c=Card(T("Conexão e bateria","Connection and battery"));
  deviceStatusText=Text("",15,Accent);
  c.Children.Add(deviceStatusText);
  UpdateDeviceLabels();
  c.Children.Add(Text(T("Use um cabo USB de dados para enviar ajustes. Consulte a bateria pelo receptor de 2,4 GHz.","Use a USB data cable to send settings. Check battery level over the 2.4 GHz receiver."),13,Muted));
  Row(c,Btn(T("Atualizar conexão e bateria","Refresh connection and battery"),()=>Run(async()=>{await Query();SetStatus(ConnectionGuidance());},false)));
  AppCard();
  var support=Card(T("Diagnóstico","Diagnostics"));
  support.Children.Add(Text(T("O relatório inclui a interface HID e a resposta do teclado.","The report includes the HID interface and keyboard response."),13,Muted));
  Row(support,Btn(T("Exportar diagnóstico","Export diagnostics"),()=>{
   var d=new SaveFileDialog{Filter="Text (*.txt)|*.txt",FileName="F75-diagnostics.txt"};
   if(d.ShowDialog()==true)Run(async()=>{await ExportDiagnostics(d.FileName);SetStatus(T("Diagnóstico exportado.","Diagnostics exported."));},false);
  }));
 }
 void AppCard(){
  var a=Card(T("Ao fechar a janela","When closing the window"));
  var close=new RadioButton{GroupName="closeMode",Content=T("Enviar ajustes pendentes e encerrar","Send pending settings and quit"),IsChecked=!profile.KeepInTray,Foreground=B("#EEF3FB"),Margin=new Thickness(0,4,0,10)};
  var background=new RadioButton{GroupName="closeMode",Content=T("Recolher para a bandeja","Minimize to the system tray"),IsChecked=profile.KeepInTray,Foreground=B("#EEF3FB"),Margin=new Thickness(0,0,0,10)};
  close.Checked+=(s,e)=>{profile.KeepInTray=false;RemoveTray();SaveLocal();};
  background.Checked+=(s,e)=>{profile.KeepInTray=true;SetupTray();SaveLocal();};
  a.Children.Add(close);a.Children.Add(background);
  a.Children.Add(Text(T("Na bandeja, a janela é descarregada e as consultas ficam pausadas. Para encerrar, use o menu do ícone.","In the tray, the window is unloaded and queries are paused. Use the tray icon menu to quit."),13,Muted));
 }
 void SetStatus(string s){lastStatus=s;if(status!=null)status.Text=s;}
 // Slider drags and key clicks used to rewrite session.json (+ .bak) on every step; coalesce them.
 void ScheduleSave(){if(suppressSave)return;if(saveTimer==null){saveTimer=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromMilliseconds(800)};saveTimer.Tick+=(s,e)=>SaveLocal();}saveTimer.Stop();saveTimer.Start();}
 bool SaveLocal(){
  if(saveTimer!=null)saveTimer.Stop();
  if(suppressSave)return true;
  string tmp=StatePath+".tmp";
  try{
   profile.Language=language;
   profile.Validate();
   string session=Json.SerializeSession(profile,pending);
   if(session==lastSavedSession)return true;
   Directory.CreateDirectory(DataDir);
   File.WriteAllText(tmp,session,Encoding.UTF8);
   if(File.Exists(StatePath))File.Replace(tmp,StatePath,StatePath+".bak");
   else File.Move(tmp,StatePath);
   lastSavedSession=session;
   return true;
  }catch(Exception ex){
   try{if(File.Exists(tmp))File.Delete(tmp);}catch{}
   SetStatus(T("Não foi possível salvar o perfil local. ","Could not save the local profile. ")+ex.Message);
   return false;
  }
 }
 void ReportError(Exception ex){SetStatus(T("Não foi possível concluir: ","Could not complete: ")+ex.Message);try{Directory.CreateDirectory(DataDir);string log=Path.Combine(DataDir,"errors.log");if(File.Exists(log) && new FileInfo(log).Length>524288)File.WriteAllText(log,"");File.AppendAllText(log,DateTime.UtcNow.ToString("O")+" "+ex+Environment.NewLine);}catch{}}
 void ApplySettings(KeyboardChanges changes){
  if(busy || closeRequested || changes==KeyboardChanges.None)return;
  pending|=changes;
  SaveLocal();
  Run(()=>SendPending(changes),false);
 }
 async Task SendPending(KeyboardChanges changes){
  await SendPackets(profile.PacketsFor(changes));
  awaitingUsb=false;
  pending&=~changes;
  if(SaveLocal())SetStatus(T("Ajustes enviados ao teclado por USB.","Settings sent to the keyboard over USB."));
 }
 async Task SendPackets(IEnumerable<byte[]> packets){
  await deviceGate.WaitAsync();
  try{
   await Task.Run(()=>{
    using(var keyboard=KeyboardDevice.Open()){
     keyboard.Status();
     foreach(var packet in packets)keyboard.Send(packet);
    }
   });
  }finally{deviceGate.Release();}
 }
 void UpdateDeviceLabels(){
  string transport=T("Consultando conexão…","Checking connection…"),battery=T("Bateria: aguardando leitura","Battery: waiting for reading");
  if(deviceSnapshot!=null){
   switch(deviceSnapshot.Transport){
    case "USB":transport=deviceSnapshot.Responding?T("USB conectado","USB connected"):T("USB · sem resposta","USB · no response");break;
    case "2.4 GHz":transport=T("2,4 GHz · somente consulta","2.4 GHz · status only");break;
    case "Receiver":transport=T("Receptor · sem resposta","Receiver · no response");break;
    case "Bluetooth":transport=T("Bluetooth detectado","Bluetooth detected");break;
    default:transport=T("F75 não detectado","F75 not detected");break;
   }
   battery=deviceSnapshot.BatteryPercent.HasValue?T("Bateria informada: ","Reported battery: ")+deviceSnapshot.BatteryPercent.Value+"%":T("Bateria: indisponível","Battery: unavailable");
  }
  if(connectionText!=null)connectionText.Text=transport;if(batteryText!=null){batteryText.Text=battery;batteryText.ToolTip=deviceSnapshot==null?null:deviceSnapshot.Detail;}
  if(deviceStatusText!=null){deviceStatusText.Text=transport+"\n"+battery+(deviceSnapshot==null?"":"\n"+T("Atualizado às ","Updated at ")+deviceSnapshot.CheckedAt.ToLocalTime().ToString("HH:mm:ss"));deviceStatusText.ToolTip=deviceSnapshot==null?null:deviceSnapshot.Detail;}
 }
 int statusRevision=-1;
 async Task Query(){
  await deviceGate.WaitAsync();
  try{
   int revision=connectionRevision;
   deviceSnapshot=await Task.Run(()=>KeyboardDevice.ReadStatusSnapshot());
   statusRevision=revision;
   UpdateDeviceLabels();
   if(awaitingUsb && deviceSnapshot.Transport=="USB" && deviceSnapshot.Responding){
    awaitingUsb=false;
    SetStatus(pending==KeyboardChanges.None?ConnectionGuidance():T("Cabo conectado. Envie os ajustes pendentes.","Cable connected. Send the pending settings."));
   }else if(lastStatus=="" && status!=null)status.Text=ConnectionGuidance();
  }finally{deviceGate.Release();}
 }
 async Task ExportDiagnostics(string filename){await Query();var d=deviceSnapshot;File.WriteAllText(filename,"F75 Studio 1.0\r\nHID: 1A2C:A073 FF02:0002 (USB)\r\nUTC: "+DateTime.UtcNow.ToString("O")+"\r\nTransport: "+d.Transport+"\r\nResponding: "+d.Responding+"\r\nReported battery: "+(d.BatteryPercent.HasValue?d.BatteryPercent.Value+"%":"unavailable")+"\r\nDetail: "+d.Detail+"\r\nRaw: "+(d.Raw==null?"unavailable":BitConverter.ToString(d.Raw))+"\r\n",Encoding.UTF8);}
 string ConnectionGuidance(){
  if(deviceSnapshot==null)return T("Consultando conexão…","Checking connection…");
  if(deviceSnapshot.Transport=="USB"){
   return deviceSnapshot.Responding
    ? T("USB pronto para enviar ajustes.","USB ready to send settings.")
    : T("USB sem resposta. Feche o software original e reconecte o cabo.","USB did not respond. Close the vendor software and reconnect the cable.");
  }
  return T("Conecte o F75 por um cabo USB de dados para enviar ajustes.","Connect the F75 with a USB data cable to send settings.");
 }
 async Task Refresh(){
  if(busy || refreshing || closeRequested || !UiVisible)return;
  refreshing=true;
  try{await Query();}
  catch(Exception ex){statusRevision=connectionRevision;deviceSnapshot=null;UpdateDeviceLabels();ReportError(ex);}
  finally{refreshing=false;ScheduleStatusRefresh();}
 }
 void ScheduleStatusRefresh(){
  if(!suppressSave && UiVisible && !closeRequested && statusRevision!=connectionRevision && !deviceChangeTimer.IsEnabled)deviceChangeTimer.Start();
 }
 void Run(Func<Task> action,bool sent=true){
  if(!busy && !closeRequested){var ignored=Execute(action,sent);}
 }
 async Task Execute(Func<Task> action,bool sent){
  busy=true;
  if(content!=null)content.IsEnabled=false;
  if(nav!=null)nav.IsEnabled=false;
  if(applyButton!=null)applyButton.IsEnabled=false;
  UpdateApply();
  SetStatus(T("Comunicando com o F75…","Communicating with F75…"));
  try{
   await action();
   if(sent)SetStatus(T("Comando enviado ao teclado por USB.","Command sent to the keyboard over USB."));
  }catch(KeyboardUnavailableException ex){
   awaitingUsb=true;
   string guidance=ex.Detected
    ? T("Feche o software original do teclado e reconecte o cabo.","Close the vendor software and reconnect the cable.")
    : T("Conecte o F75 por um cabo USB de dados.","Connect the F75 with a USB data cable.");
   SetStatus(guidance);
  }catch(KeyboardNoResponseException){
   awaitingUsb=true;
   SetStatus(T("O F75 não respondeu pelo USB. Feche o software original e reconecte o cabo.","The F75 did not respond over USB. Close the vendor software and reconnect the cable."));
  }catch(Exception ex){ReportError(ex);}
  finally{
   busy=false;
   if(content!=null)content.IsEnabled=true;
   if(nav!=null)nav.IsEnabled=true;
   if(applyButton!=null)applyButton.IsEnabled=true;
   UpdateApply();
   ScheduleStatusRefresh();
  }
 }
 public void Capture(string file){UpdateLayout();var bmp=new RenderTargetBitmap((int)root.ActualWidth,(int)root.ActualHeight,96,96,PixelFormats.Pbgra32);bmp.Render(root);var enc=new PngBitmapEncoder();enc.Frames.Add(BitmapFrame.Create(bmp));using(var f=File.Create(file))enc.Save(f);}
 [STAThread] public static int Main(string[] args){
  try {
   if(args.Contains("--self-test")){SelfTest.Run();return 0;}
   if(args.Contains("--diagnose")){using(var h=KeyboardDevice.Open()){Console.WriteLine("USB 1A2C:A073 FF02:0002 "+h.InputLength+"/"+h.OutputLength);Console.WriteLine(BitConverter.ToString(h.Status()));}return 0;}
   if(args.Contains("--low-latency")){using(var h=KeyboardDevice.Open()){h.Status();h.Send(Protocol.ResponseTime(1));Console.WriteLine("Response tier 1 packet sent; physical latency not measured.");}return 0;}
   bool created;using(var mutex=new Mutex(true,"Local\\F75Studio.Native",out created)){
    if(!created){MessageBox.Show("F75 Studio já está aberto / already open.");return 0;}
    // Software rendering avoids creating a Direct3D device for this static UI; --gpu restores hardware rendering for A/B tests.
    if(!args.Contains("--gpu"))RenderOptions.ProcessRenderMode=RenderMode.SoftwareOnly;
    var app=new Application();var window=new Studio();
    // Logoff/shutdown must never be held by background mode or by a keyboard write.
    app.SessionEnding+=(s,e)=>{window.canClose=true;};
    if(args.Length==2 && args[0]=="--capture"){
     window.suppressSave=true;
     bool capturing=false;
     window.ContentRendered+=async(s,e)=>{
      if(capturing)return;capturing=true;
      try{
       while(window.busy)await Task.Delay(50);
       Directory.CreateDirectory(args[1]);
       foreach(string lang in new[]{"pt-BR","en"})foreach(string pg in new[]{"light","effects","performance","macros","profiles","device"}){
        window.language=lang;window.page=pg;window.Build();window.UpdateLayout();
        await Task.Delay(30);window.Capture(Path.Combine(args[1],pg+"-"+lang+".png"));
       }
       foreach(string pg in new[]{"effects","light","effects","device","effects"}){window.page=pg;window.Build();window.UpdateLayout();}
       window.Width=820;window.Height=640;window.page="light";window.Build();window.UpdateLayout();await Task.Delay(30);window.Capture(Path.Combine(args[1],"compact.png"));
       Console.WriteLine("UI rendered: 6 pages x 2 languages + compact. Working set MiB: "+(Process.GetCurrentProcess().WorkingSet64/1048576));
      }catch(Exception ex){Console.Error.WriteLine(ex);Environment.ExitCode=1;}finally{window.Close();}
     };
    }
    if(args.Contains("--measure")){
     window.suppressSave=true;bool measuring=false;
     window.ContentRendered+=async(s,e)=>{if(measuring)return;measuring=true;while(window.busy)await Task.Delay(50);await Task.Delay(3000);var proc=Process.GetCurrentProcess();TimeSpan before=proc.TotalProcessorTime;await Task.Delay(5000);proc.Refresh();Console.WriteLine("Idle 5 seconds after 3-second warm-up: CPU ms="+(proc.TotalProcessorTime-before).TotalMilliseconds+"; working set MiB="+(proc.WorkingSet64/1048576)+"; private MiB="+(proc.PrivateMemorySize64/1048576));
      window.Hide();window.ReleaseUi();await Task.Delay(5000);proc.Refresh();before=proc.TotalProcessorTime;await Task.Delay(10000);proc.Refresh();Console.WriteLine("Hidden (UI released), idle 10 seconds: CPU ms="+(proc.TotalProcessorTime-before).TotalMilliseconds+"; working set MiB="+(proc.WorkingSet64/1048576)+"; private MiB="+(proc.PrivateMemorySize64/1048576));window.Close();};
    }
    app.Run(window);
   }return Environment.ExitCode;
  }catch(Exception ex){if(args.Length>0)Console.Error.WriteLine(ex);else MessageBox.Show(ex.Message,"F75 Studio");return 1;}
 }
}
}
