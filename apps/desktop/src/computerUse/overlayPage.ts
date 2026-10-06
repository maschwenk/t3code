/**
 * The overlay window's page. It only reacts to calls from the main process:
 * `glide` animates the cursor with precomputed keyframes on a compositor layer
 * (transform/opacity only), `fadeOut` hides it. Nothing runs between calls.
 *
 * The arrow is the agent cursor style: a thick dark outline around diagonal
 * lavender, white and blue stripes, about 1.7x the size of the system pointer.
 */
// SVG units: the outline's outer tip sits at (20,20); 1 unit = SCALE px.
const SCALE = 0.07;
const ARROW = "M39 59 L408 370 L186 371 L39 552 Z";

export const OVERLAY_HTML = `<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;pointer-events:none;user-select:none;-webkit-user-select:none}
#c{position:absolute;left:0;top:0;will-change:transform}
#k{position:absolute;left:0;top:0;opacity:0;transform-origin:0 0}
#arrow{position:absolute;overflow:visible;left:${-20 * SCALE}px;top:${-20 * SCALE}px;width:${480 * SCALE}px;height:${620 * SCALE}px;transform-origin:${20 * SCALE}px ${20 * SCALE}px;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
.ring{position:absolute;left:-18px;top:-18px;width:36px;height:36px;box-sizing:border-box;border-radius:50%;border:2.5px solid #c79ff7;box-shadow:0 0 0 1px rgba(34,34,34,.35);opacity:0}
#pill{position:absolute;left:26px;top:36px;padding:3px 8px;border-radius:999px;background:#222;border:1px solid rgba(255,255,255,.35);color:#fff;font:600 11px/14px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap;box-shadow:0 1px 3px rgba(0,0,0,.3);opacity:0}
#scroll{position:absolute;left:-34px;top:2px;width:24px;height:24px;opacity:0}
#hl{position:absolute;left:0;top:0;box-sizing:border-box;border-radius:7px;border:2px solid #c79ff7;box-shadow:0 0 0 3px rgba(142,205,240,.45);opacity:0;will-change:opacity}
</style>
<div id="hl"></div>
<div id="c">
<div id="k">
<div class="ring" id="r1"></div><div class="ring" id="r2"></div>
<svg id="scroll" viewBox="0 0 24 24" fill="none" stroke="#222" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6-6 6 6M6 21l6-6 6 6" stroke="#fff" stroke-width="5.5"/><path d="M6 9l6-6 6 6M6 21l6-6 6 6"/></svg>
<svg id="arrow" viewBox="0 0 480 620" xmlns="http://www.w3.org/2000/svg">
<defs><linearGradient id="stripes" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="360" y2="480">
<stop offset=".353" stop-color="#c79ff7"/><stop offset=".353" stop-color="#fff"/><stop offset=".387" stop-color="#fff"/><stop offset=".387" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#8ecdf0"/><stop offset=".578" stop-color="#fff"/><stop offset=".615" stop-color="#fff"/><stop offset=".615" stop-color="#c79ff7"/>
</linearGradient></defs>
<path d="${ARROW}" fill="none" stroke="rgba(255,255,255,.92)" stroke-width="66" stroke-linejoin="miter" stroke-miterlimit="8"/>
<path d="${ARROW}" fill="url(#stripes)" stroke="#222" stroke-width="38" stroke-linejoin="miter" stroke-miterlimit="8"/>
</svg>
<div id="pill"></div>
</div>
</div>
<script>
const c=document.getElementById("c"),k=document.getElementById("k"),arrow=document.getElementById("arrow"),pill=document.getElementById("pill"),
  hl=document.getElementById("hl"),scrollCue=document.getElementById("scroll"),
  r1=document.getElementById("r1"),r2=document.getElementById("r2");
const reduce=matchMedia("(prefers-reduced-motion: reduce)").matches;
const at=(p)=>"translate3d("+p[0]+"px,"+p[1]+"px,0)";
let motion,fade,visible=false;
const LABELS={doubleClick:"Double-click",rightClick:"Right-click",menu:"Open menu",type:"Typing",
  scrollUp:"Scrolling",scrollDown:"Scrolling",scrollLeft:"Scrolling",scrollRight:"Scrolling"};
const SCROLL_ROTATION={scrollUp:0,scrollRight:90,scrollDown:180,scrollLeft:270};
function show(){
  if(visible)return;
  visible=true;
  if(fade)fade.cancel();
  fade=k.animate([{opacity:0,transform:"scale(.6)"},{opacity:1,transform:"none"}],{duration:reduce?0:200,easing:"cubic-bezier(.2,.9,.3,1.25)",fill:"forwards"});
}
window.fadeOut=()=>{
  if(!visible)return;
  visible=false;
  if(fade)fade.cancel();
  fade=k.animate([{opacity:1},{opacity:0}],{duration:280,easing:"ease-in",fill:"forwards"});
};
function ripple(ring,delay,color){
  ring.style.borderColor=color;
  ring.animate([{transform:"scale(.35)",opacity:1},{transform:"scale(1.25)",opacity:0}],{duration:460,delay,easing:"cubic-bezier(.2,.7,.3,1)"});
}
function press(delay){
  arrow.animate([{transform:"scale(1)"},{transform:"scale(.84)"},{transform:"scale(1)"}],{duration:200,delay,easing:"ease-out"});
}
function highlight(bounds){
  if(!bounds)return;
  hl.style.transform="translate3d("+(bounds[0]-3)+"px,"+(bounds[1]-3)+"px,0)";
  hl.style.width=bounds[2]+6+"px";hl.style.height=bounds[3]+6+"px";
  hl.animate([{opacity:0},{opacity:1,offset:.15},{opacity:1,offset:.7},{opacity:0}],{duration:1300,easing:"ease-out"});
}
function cue(kind,bounds){
  const label=LABELS[kind];
  if(label){
    pill.textContent=label;
    pill.animate([{opacity:0,transform:"translateY(-3px)"},{opacity:1,transform:"none",offset:.12},{opacity:1,offset:.8},{opacity:0}],{duration:1500,easing:"ease-out"});
  }
  if(kind==="click"){press(0);ripple(r1,0,"#c79ff7");}
  else if(kind==="doubleClick"){press(0);press(220);ripple(r1,0,"#c79ff7");ripple(r2,220,"#8ecdf0");}
  else if(kind==="rightClick"){press(0);ripple(r1,0,"#8ecdf0");}
  else if(kind==="menu"){press(0);ripple(r1,0,"#8ecdf0");highlight(bounds);}
  else if(kind==="type"){highlight(bounds);}
  else if(kind in SCROLL_ROTATION){
    const r="rotate("+SCROLL_ROTATION[kind]+"deg) ";
    scrollCue.animate([{opacity:0,transform:r+"translateY(5px)"},{opacity:1,transform:r+"translateY(0)",offset:.3},{opacity:0,transform:r+"translateY(-7px)"}],{duration:650,iterations:2,easing:"ease-in-out"});
  }
}
// frames: [[x,y],...] local to this display, evenly spaced over duration ms.
window.glide=(frames,duration,kind,bounds)=>{
  if(motion)motion.cancel();
  const end=frames[frames.length-1];
  c.style.transform=at(end);
  show();
  if(reduce||frames.length<2||duration<=0){if(kind)cue(kind,bounds);return;}
  motion=c.animate(frames.map((p)=>({transform:at(p)})),{duration,easing:"linear"});
  const current=motion;
  current.finished.then(()=>{if(current===motion&&kind)cue(kind,bounds);},()=>{});
};
</script>`;
