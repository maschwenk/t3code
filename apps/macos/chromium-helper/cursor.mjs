// Finite compositor transitions; the isolated world owns this closed shadow root.
export const cursorSource = `(() => {
  if (globalThis.__t3AgentCursor) return;
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647;overflow:hidden';
  const shadow = host.attachShadow({mode:'closed'});
  shadow.innerHTML = '<style>:host{pointer-events:none}.pointer{position:absolute;left:0;top:0;display:none;will-change:auto}svg{overflow:visible}span{display:block;background:#7450cb;color:white;font:11px -apple-system;padding:3px 6px;border-radius:5px;margin-left:12px;white-space:nowrap}.ring{fill:none;stroke:#9570ee;stroke-width:3;opacity:0}@media(prefers-reduced-motion:reduce){.pointer{transition:none}}</style><div class="pointer"><svg width="24" height="28" viewBox="0 0 24 28"><circle class="ring" cx="0" cy="0" r="13"/><path d="M0 0L0 22L6 17L10 26L15 24L11 15L21 15Z" fill="#7450cb" stroke="white" stroke-width="1.5"/></svg><span>Agent</span></div>';
  const pointer = shadow.querySelector('.pointer'), ring = shadow.querySelector('.ring');
  let position = null, movement = null;
  const attach = () => { if (!host.isConnected) document.documentElement.append(host); };
  globalThis.__t3AgentCursor = {
    move: async (x,y,label='Agent') => {
      attach(); x=Math.max(0,Math.min(innerWidth-1,x)); y=Math.max(0,Math.min(innerHeight-1,y));
      const reduced = matchMedia('(prefers-reduced-motion:reduce)').matches;
      pointer.style.display='block'; shadow.querySelector('span').textContent=label;
      const from=position?getComputedStyle(pointer).transform:'translate(16px,16px)';
      movement?.cancel();
      const destination='translate('+x+'px,'+y+'px)';
      pointer.style.transform=destination;position={x,y};
      if (!reduced) {
        const animation=pointer.animate([{transform:from},{transform:destination}],
          {duration:240,easing:'cubic-bezier(.2,.75,.3,1)'});
        movement=animation;
        let timer;
        await Promise.race([animation.finished.catch(()=>{}),
          new Promise(resolve=>{timer=setTimeout(resolve,280);})]);
        clearTimeout(timer);
        // A hidden guest may suspend its compositor. Its base transform already
        // names the destination, so cancellation settles capture deterministically.
        animation.cancel();
        if(movement===animation)movement=null;
      }
      return position;
    },
    ensure:()=>{attach();},
    settle:()=>{attach();movement?.cancel();movement=null;},
    click:()=>{ring.getAnimations().forEach(a=>a.cancel());ring.animate([{opacity:1,transform:'scale(.6)'},{opacity:0,transform:'scale(1.5)'}],{duration:380});},
    hide:()=>{movement?.cancel();movement=null;pointer.style.display='none';},
    position:()=>position,
    state:()=>({position,visible:pointer.style.display==='block',inFlight:movement!==null,animations:pointer.getAnimations().filter(animation=>animation.playState==='running'||animation.pending).length,transform:getComputedStyle(pointer).transform})
  };
})();`;
