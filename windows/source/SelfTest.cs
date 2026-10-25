using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace F75Studio {
public static class SelfTest {
 static void Assert(bool v,string name){if(!v)throw new Exception("FAIL "+name);Console.WriteLine("PASS "+name);}
 public static void Run(){
  Assert(Protocol.ResponseTime(1).SequenceEqual(Protocol.Packet(13,1)),"response tier 1 packet");
  Assert(Protocol.Sleep(4)[6]==4,"sleep protocol range");
  var colors=new int[108];colors[15]=0x123456;colors[101]=0xABCDEF;var p=Protocol.Custom(colors,100);
  Assert(p.Count==8 && p.All(x=>x.Length==65),"custom transaction and report length");
  Assert(p[2][6+45]==0x12 && p[2][6+46]==0x34 && p[2][6+47]==0x56,"RGB channels and Esc index");
  Assert(p[7][6+33]==0xAB && p[7][6+34]==0xCD && p[7][6+35]==0xEF,"last fragment right arrow index");
  Assert(Protocol.Custom(colors,0).Skip(2).All(x=>x.Skip(6).All(b=>b==0)),"blackout has zero RGB");
  Assert(Protocol.EventTiming(false,10)==1 && Protocol.EventTiming(true,10)==129 && Protocol.EventTiming(false,1000)==52,"macro timing encoding");
  bool rejected=false;try{Protocol.Macro(42,new[]{new MacroEvent{Code=4},new MacroEvent{Code=5}});}catch(ArgumentException){rejected=true;}Assert(rejected,"reject held macro keys");
  var keys=Layout.Keys();Assert(keys.Count==81 && keys.Select(k=>k.index).Distinct().Count()==81,"81 unique vendor key positions");
  var original=new Profile();original.Colors[15]=0x123456;original.KeepInTray=true;original.Name="Perfil \"F75\" \\ ç";var round=Json.ParseProfile(Json.Serialize(original));round.Validate();Assert(round.Colors[15]==0x123456 && round.KeepInTray && round.Name==original.Name,"profile round trip");
  original.LightMode=2;Assert(Json.ParseProfile(Json.Serialize(original)).LightMode==2,"light mode round trip");
  rejected=false;try{var bad=Json.ParseProfile(Json.Serialize(original));bad.LightMode=3;bad.Validate();}catch(InvalidDataException){rejected=true;}Assert(rejected,"reject unknown light mode");
  rejected=false;try{round.Colors=new int[2];round.Validate();}catch(InvalidDataException){rejected=true;}Assert(rejected,"reject malformed profile");
  var legacy=Json.ParseProfile("{\"Version\":1,\"Name\":\"Old profile\",\"Language\":\"pt-BR\",\"Brightness\":80,\"Response\":1,\"Sleep\":2}");legacy.Validate();Assert(legacy.EffectMode==7 && legacy.EffectBrightness==5 && !legacy.KeepInTray,"legacy profiles retain effect defaults");
  Assert(Protocol.Effect(22,5,4,0,0)[6]==21 && Protocol.Effect(23,5,4,0,0)[6]==22,"experimental effect IDs skip undeclared mode 21");
  var report=new byte[]{0xaa,0x55,0xcc,0x33,0x0e,0,3};var zero=KeyboardDevice.ParseStatus(report,"USB");Assert(zero.BatteryPercent==0 && zero.Transport=="USB","zero battery remains valid and transport comes from endpoint");
  report[5]=101;Assert(!KeyboardDevice.ParseStatus(report,"2.4 GHz").BatteryPercent.HasValue,"invalid battery is unavailable instead of fabricated");
  // JavaScriptSerializer wrote this shape in 1.0; old session.json files must still load.
  var v10="{\"Version\":1,\"Name\":\"Meu F75\",\"Language\":\"en\",\"Colors\":["+string.Join(",",Enumerable.Repeat("9039054",108))+"],\"Brightness\":80,\"Response\":1,\"Sleep\":2,\"EffectMode\":7,\"EffectBrightness\":5,\"EffectSpeed\":4,\"EffectDirection\":0,\"EffectPalette\":0}";
  var p10=Json.ParseProfile(v10);p10.Validate();Assert(p10.Colors[107]==9039054 && p10.Language=="en","1.0 session file loads");
  var macro=new List<MacroEvent>{new MacroEvent{Code=224,Delay=10},new MacroEvent{Code=6,Delay=20},new MacroEvent{Code=6,Release=true,Delay=10},new MacroEvent{Code=224,Release=true,Delay=10}};
  var macroBack=Json.ParseMacro(Json.Serialize(macro));Assert(macroBack.Count==4 && macroBack[2].Release && macroBack[1].Delay==20 && Protocol.Macro(42,macroBack).Count==3,"macro JSON round trip");
  Assert(Json.ParseMacro("[{\"code\":4,\"delay\":10},{\"Code\":4,\"Release\":true,\"Delay\":10}]")[0].Code==4,"macro JSON hand-edited");
  foreach(string bad in new[]{"[","{\"Brightness\":1.5}","[{\"Code\":\"x\"}]","[] x","{\"Colors\":[1,]}"}){rejected=false;try{Json.Parse(bad);if(bad.StartsWith("[{"))Json.ParseMacro(bad);else if(bad.StartsWith("{"))Json.ParseProfile(bad);}catch(InvalidDataException){rejected=true;}Assert(rejected,"reject malformed JSON "+bad);}
  var tiny=KeyboardDevice.ParseStatus(new byte[]{0xaa,0x55,0xcc,0x33,0x0e,50,1},"2.4 GHz");Assert(tiny.BatteryPercent==50,"wireless battery parses");
  rejected=false;try{KeyboardDevice.ParseStatus(new byte[]{0xaa,0x55},"USB");}catch(ArgumentException){rejected=true;}Assert(rejected,"reject incomplete status report");
 }
}

}
