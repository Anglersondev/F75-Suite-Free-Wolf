using System;
using System.IO;
using System.Linq;

namespace F75Studio {
public class KeySpec {public string name{get;set;} public int index{get;set;} public int code{get;set;} public int[] rect{get;set;}}
public class Profile {
 public int Version{get;set;} public string Name{get;set;} public string Language{get;set;} public int[] Colors{get;set;}
 public int Brightness{get;set;} public int Response{get;set;} public int Sleep{get;set;}
 // true: × and — keep the app in the background (tray, UI released). false: closing writes everything to the keyboard and exits.
 public bool KeepInTray{get;set;}
 // Lighting the keyboard should show when everything is written on exit: 0 per-key colors, 1 firmware effect, 2 key RGB off.
 public int LightMode{get;set;}
 public int EffectMode{get;set;} public int EffectBrightness{get;set;} public int EffectSpeed{get;set;} public int EffectDirection{get;set;} public int EffectPalette{get;set;}
 public Profile(){Version=1;Name="Meu F75";Language="pt-BR";Colors=new int[108];Brightness=80;Response=1;Sleep=2;EffectMode=7;EffectBrightness=5;EffectSpeed=4;}
 public void Validate(){if(!((EffectMode>=1 && EffectMode<=20) || EffectMode==22 || EffectMode==23) || EffectBrightness<1 || EffectBrightness>5 || EffectSpeed<1 || EffectSpeed>5 || EffectDirection<0 || EffectDirection>3 || EffectPalette<0 || EffectPalette>8)throw new InvalidDataException("Efeito inválido / Invalid effect");if(Version!=1 || Colors==null || Colors.Length!=108 || Colors.Any(c=>c<0 || c>0xffffff) || Brightness<0 || Brightness>100 || Response<1 || Response>3 || Sleep<1 || Sleep>4 || (Language!="pt-BR" && Language!="en") || String.IsNullOrWhiteSpace(Name) || Name.Length>80 || LightMode<0 || LightMode>2)throw new InvalidDataException("Perfil inválido / Invalid profile");}
}
}
