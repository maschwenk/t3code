import {
  AGENT_CURSOR_CLICK,
  AGENT_CURSOR_RING,
  AGENT_CURSOR_SCALE,
  agentCursorMarkup,
} from "@t3tools/shared/agentCursor";

/**
 * The overlay window's page. It only reacts to calls from the main process:
 * `glide` animates one agent's cursor with precomputed keyframes on a
 * compositor layer (transform/opacity only), `fadeOut` hides it. Nothing runs
 * between calls. Each agent (cursor id) gets its own cursor and name tag.
 */
export const OVERLAY_HTML = `<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;pointer-events:none;user-select:none;-webkit-user-select:none}
.c{position:absolute;left:0;top:0;will-change:transform}
.k{position:absolute;left:0;top:0;opacity:0;transform-origin:0 0}
.tags{position:absolute;left:${Math.round(340 * AGENT_CURSOR_SCALE)}px;top:${Math.round(470 * AGENT_CURSOR_SCALE)}px;display:flex;gap:4px;font:600 11px/14px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap}
.tag,.pill{padding:2px 7px;border-radius:999px;box-shadow:0 1px 3px rgba(0,0,0,.3)}
.tag{color:#222;border:1px solid #222}
.pill{background:#222;border:1px solid rgba(255,255,255,.35);color:#fff;opacity:0}
.scroll{position:absolute;left:-34px;top:2px;width:24px;height:24px;opacity:0}
.hl{position:absolute;left:0;top:0;box-sizing:border-box;border-radius:8px;border:2px solid #c79ff7;box-shadow:0 0 0 3px rgba(142,205,240,.45);opacity:0;will-change:opacity}
</style>
<template id="cursor"><div class="hl"></div><div class="c"><div class="k">
${AGENT_CURSOR_RING}
<svg class="scroll" viewBox="0 0 24 24" fill="none" stroke="#222" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6-6 6 6M6 21l6-6 6 6" stroke="#fff" stroke-width="5.5"/><path d="M6 9l6-6 6 6M6 21l6-6 6 6"/></svg>
${agentCursorMarkup("stripes")}
<div class="tags"><span class="tag"></span><span class="pill"></span></div>
</div></div></template>
<script>
const template=document.getElementById("cursor");
const reduce=matchMedia("(prefers-reduced-motion: reduce)").matches;
const CLICK=${JSON.stringify(AGENT_CURSOR_CLICK)};
const at=(p)=>"translate3d("+p[0]+"px,"+p[1]+"px,0)";
const TONES=["#c79ff7","#8ecdf0","#f5a9cc","#a6e3bf"];
const LABELS={look:"Looking",doubleClick:"Double-click",rightClick:"Right-click",menu:"Open menu",type:"Typing",
  scrollUp:"Scrolling",scrollDown:"Scrolling",scrollLeft:"Scrolling",scrollRight:"Scrolling"};
const SCROLL_ROTATION={scrollUp:0,scrollRight:90,scrollDown:180,scrollLeft:270};
const cursors=new Map();
function cursorFor(id){
  let cur=cursors.get(id);
  if(cur)return cur;
  const root=template.content.cloneNode(true);
  const q=(s)=>root.querySelector(s);
  const rings=root.querySelectorAll("[data-agent-cursor-ring]");
  cur={hl:q(".hl"),c:q(".c"),k:q(".k"),arrow:q("[data-agent-cursor-arrow]"),tag:q(".tag"),pill:q(".pill"),scroll:q(".scroll"),
    r1:rings[0],r2:rings[1],motion:null,fade:null,visible:false};
  document.body.appendChild(root);
  cursors.set(id,cur);
  return cur;
}
function show(cur){
  if(cur.visible)return;
  cur.visible=true;
  if(cur.fade)cur.fade.cancel();
  cur.fade=cur.k.animate([{opacity:0,transform:"scale(.6)"},{opacity:1,transform:"none"}],{duration:reduce?0:200,easing:"cubic-bezier(.2,.9,.3,1.25)",fill:"forwards"});
}
window.fadeOut=(id)=>{
  const cur=cursors.get(id);
  if(!cur||!cur.visible)return;
  cur.visible=false;
  if(cur.fade)cur.fade.cancel();
  cur.fade=cur.k.animate([{opacity:1},{opacity:0}],{duration:280,easing:"ease-in",fill:"forwards"});
};
function ripple(ring,delay,color){
  ring.style.borderColor=color;
  ring.animate(CLICK.ripple.keyframes,{...CLICK.ripple.timing,delay});
}
function press(cur,delay){
  cur.arrow.animate(CLICK.press.keyframes,{...CLICK.press.timing,delay});
}
function highlight(cur,bounds,strength,duration){
  if(!bounds)return;
  cur.hl.style.transform="translate3d("+(bounds[0]-3)+"px,"+(bounds[1]-3)+"px,0)";
  cur.hl.style.width=bounds[2]+6+"px";cur.hl.style.height=bounds[3]+6+"px";
  cur.hl.animate([{opacity:0},{opacity:strength,offset:.15},{opacity:strength,offset:.7},{opacity:0}],{duration,easing:"ease-out"});
}
function cue(cur,kind,bounds){
  const label=LABELS[kind];
  if(label){
    cur.pill.textContent=label;
    cur.pill.animate([{opacity:0,transform:"translateX(-3px)"},{opacity:1,transform:"none",offset:.12},{opacity:1,offset:.8},{opacity:0}],{duration:1500,easing:"ease-out"});
  }
  if(kind==="click"){press(cur,0);ripple(cur.r1,0,"#c79ff7");}
  else if(kind==="doubleClick"){press(cur,0);press(cur,220);ripple(cur.r1,0,"#c79ff7");ripple(cur.r2,220,"#8ecdf0");}
  else if(kind==="rightClick"){press(cur,0);ripple(cur.r1,0,"#8ecdf0");}
  else if(kind==="menu"){press(cur,0);ripple(cur.r1,0,"#8ecdf0");highlight(cur,bounds,1,1300);}
  else if(kind==="type"){highlight(cur,bounds,1,1300);}
  else if(kind==="look"){highlight(cur,bounds,.55,1100);}
  else if(kind in SCROLL_ROTATION){
    const r="rotate("+SCROLL_ROTATION[kind]+"deg) ";
    cur.scroll.animate([{opacity:0,transform:r+"translateY(5px)"},{opacity:1,transform:r+"translateY(0)",offset:.3},{opacity:0,transform:r+"translateY(-7px)"}],{duration:650,iterations:2,easing:"ease-in-out"});
  }
}
// frames: [[x,y],...] local to this display, evenly spaced over duration ms.
window.glide=(id,frames,duration,kind,bounds,name,tone)=>{
  const cur=cursorFor(id);
  if(cur.tag.textContent!==name)cur.tag.textContent=name;
  cur.tag.style.background=TONES[tone%TONES.length];
  if(cur.motion)cur.motion.cancel();
  cur.c.style.transform=at(frames[frames.length-1]);
  show(cur);
  if(reduce||frames.length<2||duration<=0){if(kind)cue(cur,kind,bounds);return;}
  const motion=cur.c.animate(frames.map((p)=>({transform:at(p)})),{duration,easing:"linear"});
  cur.motion=motion;
  motion.finished.then(()=>{if(cur.motion===motion&&kind)cue(cur,kind,bounds);},()=>{});
};
</script>`;
