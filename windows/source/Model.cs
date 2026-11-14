using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace F75Studio {
public class KeySpec {public string name{get;set;} public int index{get;set;} public int code{get;set;} public int[] rect{get;set;}}
[Flags]
public enum KeyboardChanges {
 None=0, Lighting=1, Response=2, Sleep=4,
 Performance=Response|Sleep, All=Lighting|Performance
}
public class Profile {
 public int Version{get;set;} public string Name{get;set;} public string Language{get;set;} public int[] Colors{get;set;}
 public int Brightness{get;set;} public int Response{get;set;} public int Sleep{get;set;}
 // true: × and — keep the app in the background (tray, UI released). false: closing sends pending changes and exits.
 public bool KeepInTray{get;set;}
 // Selected keyboard lighting: 0 per-key colors, 1 firmware effect, 2 key RGB off.
 public int LightMode{get;set;}
 public int EffectMode{get;set;} public int EffectBrightness{get;set;} public int EffectSpeed{get;set;} public int EffectDirection{get;set;} public int EffectPalette{get;set;}
 public List<byte[]> PacketsFor(KeyboardChanges changes){
  var packets=new List<byte[]>();
  if((changes & KeyboardChanges.Lighting)!=0){
   if(LightMode==1)packets.Add(Protocol.Effect(EffectMode,EffectBrightness,EffectSpeed,EffectDirection,EffectPalette));
   else packets.AddRange(Protocol.Custom(Colors,LightMode==2?0:Brightness));
  }
  if((changes & KeyboardChanges.Response)!=0)packets.Add(Protocol.ResponseTime(Response));
  if((changes & KeyboardChanges.Sleep)!=0)packets.Add(Protocol.Sleep(Sleep));
  return packets;
 }
 public Profile(){Version=1;Name="Meu F75";Language="pt-BR";Colors=new int[108];Brightness=80;Response=1;Sleep=2;EffectMode=7;EffectBrightness=5;EffectSpeed=4;}
 public void Validate(){if(!((EffectMode>=1 && EffectMode<=20) || EffectMode==22 || EffectMode==23) || EffectBrightness<1 || EffectBrightness>5 || EffectSpeed<1 || EffectSpeed>5 || EffectDirection<0 || EffectDirection>3 || EffectPalette<0 || EffectPalette>8)throw new InvalidDataException("Efeito inválido / Invalid effect");if(Version!=1 || Colors==null || Colors.Length!=108 || Colors.Any(c=>c<0 || c>0xffffff) || Brightness<0 || Brightness>100 || Response<1 || Response>3 || Sleep<1 || Sleep>4 || (Language!="pt-BR" && Language!="en") || String.IsNullOrWhiteSpace(Name) || Name.Length>80 || LightMode<0 || LightMode>2)throw new InvalidDataException("Perfil inválido / Invalid profile");}
}
}
