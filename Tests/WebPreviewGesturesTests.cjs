// Run with: node Tests/WebPreviewGesturesTests.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(new URL('../Sources/PhoneUseCLI/WebPreviewPage.swift', `file://${__filename}`), 'utf8');
const script = source.split('<script id="controls">')[1].split('</script>')[0];
const listeners = {}, windowListeners = {}, requests = [];
let now = 0, captured = null;
const screen = {
  naturalWidth: 590, naturalHeight: 1280,
  getBoundingClientRect: () => ({left:20, top:10, width:295, height:640}),
  addEventListener: (name, handler) => listeners[name] = handler,
  setPointerCapture: id => captured = id,
  releasePointerCapture: id => { captured = null; listeners.lostpointercapture?.({pointerId:id}); },
  hasPointerCapture: id => captured === id,
};
const status = {dataset:{}};
const button = {dataset:{button:'home'}, addEventListener: (_, handler) => button.click = handler};
const context = vm.createContext({
  document: {
    getElementById: id => id === 'screen' ? screen : status,
    querySelectorAll: () => [button], querySelector: () => ({content:'test-token'}),
  },
  window: {addEventListener: (name, handler) => windowListeners[name] = handler},
  performance: {now: () => now},
  fetch: async (url, options) => {
    requests.push({url, headers: options.headers, ...JSON.parse(options.body)});
    return {ok:true, json:async () => ({status:'ok'})};
  },
});
vm.runInContext(script, context);
const event = (x, y) => ({clientX:x, clientY:y, pointerId:1, button:0, isPrimary:true, preventDefault(){}});
const settle = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  listeners.pointerdown(event(167.5,330)); now += 100; listeners.pointerup(event(167.5,330));
  await settle();
  assert.equal(requests[0].action,'tap'); assert.equal(requests[0].x,.5); assert.equal(requests[0].y,.5);
  assert.equal(requests[0].headers['X-PhoneUse-Token'],'test-token');
  listeners.pointerdown(event(167.5,330)); now += 750; listeners.pointerup(event(167.5,330));
  await settle(); assert.equal(requests[1].action,'longpress'); assert.equal(requests[1].duration,750);
  listeners.pointerdown(event(167.5,330)); now += 350;
  listeners.pointermove(event(1000,-100)); listeners.pointerup(event(1000,-100));
  await settle(); assert.equal(requests[2].action,'swipe'); assert.equal(requests[2].toX,1); assert.equal(requests[2].toY,0);
  listeners.pointerdown(event(100,100)); windowListeners.keydown({key:'Escape'}); listeners.pointerup(event(100,100));
  listeners.pointerdown(event(100,100)); listeners.pointercancel(); listeners.pointerup(event(100,100));
  listeners.pointerdown(event(100,100)); windowListeners.blur(); listeners.pointerup(event(100,100));
  await settle(); assert.equal(requests.length,3);
  listeners.pointerdown(event(100,100)); screen.naturalWidth = 1280; screen.naturalHeight = 590;
  listeners.pointerup(event(100,100)); await settle(); assert.equal(requests.length,3);
  assert.equal(status.dataset.error,'true');
  button.click(); button.click(); await settle();
  assert.equal(requests.length,4); assert.equal(requests[3].button,'home'); assert.equal(button.disabled,false);
  console.log('Web gestures: tap, long press, swipe, coordinate mapping, cancellation, orientation, busy state passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
