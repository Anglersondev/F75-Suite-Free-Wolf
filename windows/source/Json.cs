using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace F75Studio {
// Minimal JSON for profiles and macros; replaces System.Web.Extensions (JavaScriptSerializer) to keep it out of memory.
public static class Json {
 public const int MaxLength=131072;
 public static object Parse(string text){
  if(text==null || text.Length>MaxLength)throw new InvalidDataException("JSON too large");
  int i=0;object v=Value(text,ref i,0);Skip(text,ref i);
  if(i!=text.Length)throw new InvalidDataException("JSON: trailing data");
  return v;
 }
 static void Skip(string s,ref int i){while(i<s.Length && (s[i]==' ' || s[i]=='\t' || s[i]=='\r' || s[i]=='\n' || s[i]=='﻿'))i++;}
 static InvalidDataException Bad(int i){return new InvalidDataException("JSON inválido / invalid at "+i);}
 static object Value(string s,ref int i,int depth){
  if(depth>16)throw Bad(i);
  Skip(s,ref i);if(i>=s.Length)throw Bad(i);
  char c=s[i];
  if(c=='{'){
   var o=new Dictionary<string,object>(StringComparer.OrdinalIgnoreCase);i++;Skip(s,ref i);
   if(i<s.Length && s[i]=='}'){i++;return o;}
   while(true){Skip(s,ref i);if(i>=s.Length || s[i]!='"')throw Bad(i);string k=Str(s,ref i);Skip(s,ref i);if(i>=s.Length || s[i]!=':')throw Bad(i);i++;o[k]=Value(s,ref i,depth+1);Skip(s,ref i);if(i<s.Length && s[i]==','){i++;continue;}if(i<s.Length && s[i]=='}'){i++;return o;}throw Bad(i);}
  }
  if(c=='['){
   var a=new List<object>();i++;Skip(s,ref i);
   if(i<s.Length && s[i]==']'){i++;return a;}
   while(true){a.Add(Value(s,ref i,depth+1));Skip(s,ref i);if(i<s.Length && s[i]==','){i++;continue;}if(i<s.Length && s[i]==']'){i++;return a;}throw Bad(i);}
  }
  if(c=='"')return Str(s,ref i);
  if(Word(s,ref i,"true"))return true;
  if(Word(s,ref i,"false"))return false;
  if(Word(s,ref i,"null"))return null;
  int start=i;
  while(i<s.Length && (char.IsDigit(s[i]) || s[i]=='-' || s[i]=='+' || s[i]=='.' || s[i]=='e' || s[i]=='E'))i++;
  double d;
  if(i==start || !double.TryParse(s.Substring(start,i-start),NumberStyles.Float,CultureInfo.InvariantCulture,out d))throw Bad(start);
  return d;
 }
 static bool Word(string s,ref int i,string w){if(string.CompareOrdinal(s,i,w,0,w.Length)!=0)return false;i+=w.Length;return true;}
 static string Str(string s,ref int i){
  var b=new StringBuilder();i++;
  while(i<s.Length){
   char c=s[i++];
   if(c=='"')return b.ToString();
   if(c!='\\'){b.Append(c);continue;}
   if(i>=s.Length)break;
   char e=s[i++];
   switch(e){case '"':b.Append('"');break;case '\\':b.Append('\\');break;case '/':b.Append('/');break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;
    case 'u':if(i+4>s.Length)throw Bad(i);b.Append((char)int.Parse(s.Substring(i,4),NumberStyles.HexNumber,CultureInfo.InvariantCulture));i+=4;break;
    default:throw Bad(i);}
  }
  throw Bad(i);
 }
 public static string Quote(string s){
  var b=new StringBuilder("\"");
  foreach(char c in s){if(c=='"' || c=='\\'){b.Append('\\').Append(c);}else if(c<' '){b.Append("\\u").Append(((int)c).ToString("x4"));}else b.Append(c);}
  return b.Append('"').ToString();
 }
 static int Int(Dictionary<string,object> o,string key,int fallback){
  object v;if(!o.TryGetValue(key,out v) || v==null)return fallback;
  if(!(v is double))throw new InvalidDataException("JSON: "+key+" must be a number");
  double d=(double)v;if(d!=Math.Floor(d) || d<int.MinValue || d>int.MaxValue)throw new InvalidDataException("JSON: "+key+" must be an integer");
  return (int)d;
 }
 static Dictionary<string,object> Obj(object v){var o=v as Dictionary<string,object>;if(o==null)throw new InvalidDataException("JSON: object expected");return o;}
 public static Profile ParseProfile(string text){
  var o=Obj(Parse(text));var p=new Profile();object v;
  p.Version=Int(o,"Version",p.Version);
  if(o.TryGetValue("Name",out v))p.Name=v as string;
  if(o.TryGetValue("Language",out v))p.Language=v as string;
  if(o.TryGetValue("Colors",out v)){
   var list=v as List<object>;if(list==null)throw new InvalidDataException("JSON: Colors");
   p.Colors=new int[list.Count];
   for(int i=0;i<list.Count;i++){if(!(list[i] is double))throw new InvalidDataException("JSON: Colors");double d=(double)list[i];if(d!=Math.Floor(d) || d<int.MinValue || d>int.MaxValue)throw new InvalidDataException("JSON: Colors");p.Colors[i]=(int)d;}
  }
  p.Brightness=Int(o,"Brightness",p.Brightness);p.Response=Int(o,"Response",p.Response);p.Sleep=Int(o,"Sleep",p.Sleep);
  p.EffectMode=Int(o,"EffectMode",p.EffectMode);p.EffectBrightness=Int(o,"EffectBrightness",p.EffectBrightness);p.EffectSpeed=Int(o,"EffectSpeed",p.EffectSpeed);
  p.EffectDirection=Int(o,"EffectDirection",p.EffectDirection);p.EffectPalette=Int(o,"EffectPalette",p.EffectPalette);
  p.LightMode=Int(o,"LightMode",p.LightMode);
  if(o.TryGetValue("KeepInTray",out v)){if(!(v is bool))throw new InvalidDataException("JSON: KeepInTray");p.KeepInTray=(bool)v;}
  return p;
 }
 public static string Serialize(Profile p){
  var b=new StringBuilder();
  b.Append("{\"Version\":").Append(p.Version).Append(",\"Name\":").Append(Quote(p.Name??"")).Append(",\"Language\":").Append(Quote(p.Language??"")).Append(",\"Colors\":[");
  for(int i=0;i<p.Colors.Length;i++){if(i>0)b.Append(',');b.Append(p.Colors[i]);}
  b.Append("],\"Brightness\":").Append(p.Brightness).Append(",\"Response\":").Append(p.Response).Append(",\"Sleep\":").Append(p.Sleep)
   .Append(",\"EffectMode\":").Append(p.EffectMode).Append(",\"EffectBrightness\":").Append(p.EffectBrightness).Append(",\"EffectSpeed\":").Append(p.EffectSpeed)
   .Append(",\"EffectDirection\":").Append(p.EffectDirection).Append(",\"EffectPalette\":").Append(p.EffectPalette)
   .Append(",\"LightMode\":").Append(p.LightMode).Append(",\"KeepInTray\":").Append(p.KeepInTray?"true":"false").Append('}');
  return b.ToString();
 }
 public static List<MacroEvent> ParseMacro(string text){
  var list=Parse(text) as List<object>;if(list==null)throw new InvalidDataException("JSON: array expected");
  var events=new List<MacroEvent>();
  foreach(var item in list){
   var o=Obj(item);object r;bool release=false;
   if(o.TryGetValue("Release",out r) && r!=null){if(!(r is bool))throw new InvalidDataException("JSON: Release");release=(bool)r;}
   events.Add(new MacroEvent{Code=Int(o,"Code",0),Release=release,Delay=Int(o,"Delay",0)});
  }
  return events;
 }
 public static string Serialize(IList<MacroEvent> events){
  var b=new StringBuilder("[");
  for(int i=0;i<events.Count;i++){if(i>0)b.Append(',');var e=events[i];b.Append("{\"Code\":").Append(e.Code).Append(",\"Release\":").Append(e.Release?"true":"false").Append(",\"Delay\":").Append(e.Delay).Append('}');}
  return b.Append(']').ToString();
 }
}
}
