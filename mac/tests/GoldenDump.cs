// Prints packets and JSON from the Windows C# code (Device.cs, Json.cs, Model.cs, Layout.cs) for comparison with golden_dump.c.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
namespace F75Studio {
public static class GoldenDump {
 static string H(byte[] b){return BitConverter.ToString(b).Replace("-","");}
 static void P(string name,byte[] b){Console.WriteLine(name+" "+H(b));}
 static void L(string name,List<byte[]> l){for(int i=0;i<l.Count;i++)P(name+"."+i,l[i]);}
 public static void Main(){
  for(int t=1;t<=3;t++)P("response"+t,Protocol.ResponseTime(t));
  for(int t=1;t<=4;t++)P("sleep"+t,Protocol.Sleep(t));
  foreach(int m in Enumerable.Range(1,20).Concat(new[]{22,23,24}))P("effect"+m,Protocol.Effect(m,1+m%5,1+(m*3)%5,m%4,m%9));
  var colors=new int[108];for(int i=0;i<108;i++)colors[i]=(i*2654435761u%0xffffff)>0?(int)(i*2654435761u%0xffffff):0;
  foreach(int br in new[]{0,1,37,80,100})L("custom"+br,Protocol.Custom(colors,br));
  for(int ms=0;ms<=31000;ms+=ms<400?10:ms<4000?50:500){Console.WriteLine("timing"+ms+" "+Protocol.EventTiming(false,ms)+" "+Protocol.EventTiming(true,ms));}
  var ev=new List<MacroEvent>();for(int i=0;i<30;i++){ev.Add(new MacroEvent{Code=4+i,Delay=i*37});}for(int i=29;i>=0;i--){ev.Add(new MacroEvent{Code=4+i,Release=true,Delay=i*101});}
  L("macro",Protocol.Macro(77,ev));
  Console.WriteLine("macrojson "+Json.Serialize(ev));
  P("restore",Protocol.Packet(4,1,77,0));
  foreach(var k in Layout.Keys())Console.WriteLine("key "+k.name+" "+k.index+" "+k.code+" "+string.Join(",",k.rect));
  var p=new Profile();foreach(var k in Layout.Keys())p.Colors[k.index]=0x89F0CE;p.Name="Ação \"x\" \\ \t ✓";p.Colors[3]=0xABCDEF;p.Brightness=33;p.EffectPalette=4;
  Console.WriteLine("profile "+Json.Serialize(p));
  var q=Json.ParseProfile("{\"name\":\"\\u00e7\\ud83d\\ude00 a\",\"NAME\":\"dup \\u0041\",\"colors\":["+string.Join(",",Enumerable.Repeat("1e3",108))+"],\"brightness\":5.0,\"sleep\":null}");
  Console.WriteLine("parsed "+Json.Serialize(q));
 }
}}
