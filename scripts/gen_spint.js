const https=require("https"),fs=require("fs");
const TOK=process.env.TOK;
function g(u){return new Promise(r=>{https.get(u,{headers:{Accept:"application/json"}},res=>{let d="";res.on("data",c=>d+=c);res.on("end",()=>{try{r(JSON.parse(d))}catch(e){r({})}})}).on("error",()=>r({}))});}
const isSP=t=>/^[A-Za-z]\d{2,3}$/.test((t||"").trim());
(async()=>{
  const D=JSON.parse(fs.readFileSync("public/data.js","utf8").replace(/^window\.REPORT_DATA = /,"").replace(/;\s*$/,""));
  const pages=Object.keys(D.markets.find(x=>x.key==="th").pages_meta);
  let old={};
  try{ old=JSON.parse(fs.readFileSync("public/tags.js","utf8").replace(/^window\.TAGINT_DATA = /,"").replace(/;\s*$/,"")); }catch(e){}
  const spInt=(old.sp_int)||{};
  let pgOK=0;
  for(const pid of pages){
    const st=await g(`https://pages.fm/api/v1/pages/${pid}/settings?access_token=${TOK}`);
    const tags=(st.settings&&st.settings.tags)||[]; if(!tags.length) continue;
    const id2sp={}; for(const t of tags){ if(isSP(t.text)) id2sp[t.id]=t.text.trim().toUpperCase(); }
    if(!Object.keys(id2sp).length) continue; pgOK++;
    const cv=await g(`https://pages.fm/api/v1/pages/${pid}/conversations?access_token=${TOK}&page_size=60`);
    const cur={};
    for(const c of (cv.conversations||[])){ const dk=(""+c.inserted_at).slice(0,10);
      for(const tid of (c.tags||[])){ const sp=id2sp[tid]; if(!sp) continue; (cur[sp]=cur[sp]||{})[dk]=((cur[sp]||{})[dk]||0)+1; } }
    for(const sp in cur) for(const dk in cur[sp]){ (spInt[sp]=spInt[sp]||{})[dk]=Math.max((spInt[sp][dk])||0, cur[sp][dk]); }
  }
  old.sp_int=spInt;
  fs.writeFileSync("public/tags.js","window.TAGINT_DATA = "+JSON.stringify(old)+";");
  console.log("Page doc settings:",pgOK,"| SP:",Object.keys(spInt).join(", "));
  const today=D.today;
  for(const sp of Object.keys(spInt).sort()){ let tt=0; for(const d in spInt[sp]) tt+=spInt[sp][d]; console.log("  "+sp+": today "+(spInt[sp][today]||0)+" | total "+tt); }
})();
