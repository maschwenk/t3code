// Runs in the browser's isolated automation content world.
return (() => {
  const injected = globalThis.__t3PlaywrightInjected;
  const fail = (tag, message) => ({ error: { _tag: tag, message } });
  const locator = input.locator ?? (input.selector ? 'css=' + input.selector : null);
  let element;
  try {
    if (locator) element = injected.querySelector(injected.parseSelector(locator), document, true);
  } catch (error) { return fail('PreviewAutomationInvalidSelectorError', String(error)); }
  const deepActive = () => { let node = document.activeElement; while (node?.shadowRoot?.activeElement) node = node.shadowRoot.activeElement; return node; };
  const visible = node => node && injected.elementState(node, 'visible').matches;
  switch (operation) {
    case 'viewport': return {width: innerWidth, height: innerHeight};
    case 'ready': return document.readyState;
    case 'click': {
      if (!locator) return {x:input.x, y:input.y};
      if (!visible(element) || !injected.elementState(element, 'enabled').matches) return {pending:true};
      element.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
      const rect = element.getBoundingClientRect();
      const x = Math.max(0, rect.left) + (Math.min(innerWidth, rect.right) - Math.max(0, rect.left)) / 2;
      const y = Math.max(0, rect.top) + (Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top)) / 2;
      const hit = injected.expectHitTarget({x,y}, element);
      if (hit !== 'done') return {pending:true};
      return {x,y};
    }
    case 'type': {
      if (locator && !element) return {pending:true};
      element ??= deepActive();
      const textControl = element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement && !['button','checkbox','color','file','hidden','image','radio','range','reset','submit'].includes(element.type);
      if (!element || !visible(element) || !(textControl || element.isContentEditable) || element.disabled || element.readOnly)
        return fail('PreviewAutomationTargetNotEditableError', 'The target is not an editable field.');
      element.focus();
      if (deepActive() !== element) return fail('PreviewAutomationTargetNotEditableError', 'The target could not be focused.');
      if (input.clear) {
        if (textControl) element.select();
        else { const range = document.createRange(); range.selectNodeContents(element); const selection = document.getSelection(); selection.removeAllRanges(); selection.addRange(range); }
      }
      if (input.text.length) {
        if (!document.execCommand('insertText', false, input.text)) return fail('PreviewAutomationTargetNotEditableError', 'The page did not accept text.');
      } else if (input.clear) document.execCommand('delete', false);
      element.dispatchEvent(new Event('change', {bubbles:true}));
      return {ok:true};
    }
    case 'scroll': {
      if (locator && !element) return fail('PreviewAutomationTargetNotFoundError','The scroll target was not found.');
      (element ?? window).scrollBy({left:input.deltaX ?? 0, top:input.deltaY ?? 0, behavior:'instant'});
      return {ok:true};
    }
    case 'waitFor': return {
      pending: Boolean(locator && !visible(element) || input.text && !(document.body?.innerText ?? '').includes(input.text) || input.urlIncludes && !location.href.includes(input.urlIncludes))
    };
    case 'snapshot': {
      const roots = [document];
      const elements = [];
      let visited = 0;
      for (let index = 0; index < roots.length && visited < 8000 && elements.length < 200; index++) {
        const walker = document.createTreeWalker(roots[index], NodeFilter.SHOW_ELEMENT);
        let node;
        while ((node = walker.nextNode()) && visited++ < 8000 && elements.length < 200) {
          if (node.shadowRoot) roots.push(node.shadowRoot);
          if (elements.length >= 200 || !node.matches('a[href],button,input,textarea,select,[role],[tabindex]') || !visible(node)) continue;
          const rect = node.getBoundingClientRect();
          elements.push({tag:node.localName, role:node.getAttribute('role'),
            name:(node.getAttribute('aria-label') || node.innerText || node.getAttribute('name') || '').slice(0,160),
            selector:injected.generateSelectorSimple(node), x:rect.x,y:rect.y,width:rect.width,height:rect.height});
        }
      }
      return {url:location.href,title:document.title,loading:document.readyState !== 'complete',
        visibleText:(document.body?.innerText ?? '').slice(0,32000),interactiveElements:elements,
        accessibilityTree:injected.ariaSnapshot(document.body ?? document.documentElement,{mode:'ai'}).slice(0,64000),
        consoleEntries:[],networkEntries:[]};
    }
    default: return fail('PreviewAutomationUnsupportedClientError', 'Unsupported browser operation: ' + operation);
  }
})();
