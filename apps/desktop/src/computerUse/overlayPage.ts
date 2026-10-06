/**
 * The overlay window's page. It only reacts to calls from the main process:
 * `glide` animates one agent's cursor with precomputed keyframes on a
 * compositor layer (transform/opacity only), `fadeOut` hides it. Nothing runs
 * between calls. Each agent (cursor id) gets its own cursor and name tag.
 *
 * The arrow is the agent cursor style: a thick dark outline around diagonal
 * lavender, white and blue stripes, about 1.7x the size of the system pointer.
 */
// SVG units: the outline's outer tip sits at (20,20); 1 unit = SCALE px.
const SCALE = 0.07;
const ARROW = "M39 59 L408 370 L186 371 L39 552 Z";

export const OVERLAY_HTML = `<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;pointer-events:none;user-select:none;-webkit-user-select:none}
.c{position:absolute;left:0;top:0;will-change:transform}
.k{position:absolute;left:0;top:0;opacity:0;transform-origin:0 0}
.arrow{position:absolute;overflow:visible;left:${-20 * SCALE}px;top:${-20 * SCALE}px;width:${480 * SCALE}px;height:${620 * SCALE}px;transform-origin:${20 * SCALE}px ${20 * SCALE}px;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
.ring{position:absolute;left:-18px;top:-18px;width:36px;height:36px;box-sizing:border-box;border-radius:50%;border:2.5px solid #c79ff7;box-shadow:0 0 0 1px rgba(34,34,34,.35);opacity:0}
.tags{position:absolute;left:24px;top:33px;display:flex;gap:4px;font:600 11px/14px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap}
.tag,.pill{padding:2px 7px;border-radius:999px;box-shadow:0 1px 3px rgba(0,0,0,.3)}
.tag{color:#222;border:1px solid #222}
.pill{background:#222;border:1px solid rgba(255,255,255,.35);color:#fff;opacity:0}
.scroll{position:absolute;left:-34px;top:2px;width:24px;height:24px;opacity:0}
.hl{position:absolute;left:0;top:0;box-sizing:border-box;border-radius:8px;border:2px solid #c79ff7;box-shadow:0 0 0 3px rgba(142,205,240,.45);opacity:0;will-change:opacity}
</style>
<svg width="0" height="0" style="position:absolute"><defs><linearGradient id="stripes" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="360" y2="480">
<stop offset=".353" stop-color="#c79ff7"/><stop offset=".353" stop-color="#fff"/><stop offset=".387" stop-color="#fff"/><stop offset=".387" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#fff"/><stop offset=".615" stop-color="#fff"/><stop offset=".615" stop-color="#c79ff7"/>
</linearGradient></defs></svg>
<template id="cursor"><div class="hl"></div><div class="c"><div class="k">
<div class="ring"></div><div class="ring"></div>
<svg class="scroll" viewBox="0 0 24 24" fill="none" stroke="#222" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6-6 6 6M6 21l6-6 6 6" stroke="#fff" stroke-width="5.5"/><path d="M6 9l6-6 6 6M6 21l6-6 6 6"/></svg>
<svg class="arrow" viewBox="0 0 480 620" xmlns="http://www.w3.org/2000/svg">
<path d="${ARROW}" fill="none" stroke="rgba(255,255,255,.92)" stroke-width="66" stroke-linejoin="miter" stroke-miterlimit="8"/>
<path d="${ARROW}" fill="url(#stripes)" stroke="#222" stroke-width="38" stroke-linejoin="miter" stroke-miterlimit="8"/>
</svg>
<div class="tags"><span class="tag"></span><span class="pill"></span></div>
</div></div></template>
<script>
const template=document.getElementById("cursor");
const reduce=matchMedia("(prefers-reduced-motion: reduce)").matches;
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
  const rings=root.querySelectorAll(".ring");
  cur={hl:q(".hl"),c:q(".c"),k:q(".k"),arrow:q(".arrow"),tag:q(".tag"),pill:q(".pill"),scroll:q(".scroll"),
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
  ring.animate([{transform:"scale(.35)",opacity:1},{transform:"scale(1.25)",opacity:0}],{duration:460,delay,easing:"cubic-bezier(.2,.7,.3,1)"});
}
function press(cur,delay){
  cur.arrow.animate([{transform:"scale(1)"},{transform:"scale(.84)"},{transform:"scale(1)"}],{duration:200,delay,easing:"ease-out"});
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
