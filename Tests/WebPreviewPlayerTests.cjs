const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(new URL('../Sources/PhoneUseCLI/WebPreviewPage.swift', `file://${__filename}`),'utf8');
const script = source.split('<script id="player">')[1].split('</script>')[0];
function setup(supported=true) {
  let ws, vd, timer, drawn=0, closed=0, now=0;
  const elements = Object.fromEntries(['video','fallback','connection','reconnect'].map(id=>[id,{hidden:true,dataset:{},listeners:{},addEventListener(name,fn){this.listeners[name]=fn;}}]));
  elements.video.getContext = ()=>({drawImage(){drawn++;}});
  const screen={style:{setProperty(){}}};
  class Decoder {
    constructor(options){this.callbacks=options;this.state='unconfigured';this.decodeQueueSize=0;this.chunks=[];vd=this;}
    reset(){this.state='unconfigured';this.decodeQueueSize=0;}
    configure(config){this.config=config;this.state='configured';}
    close(){this.state='closed';}
    decode(chunk){assert.equal(this.state,'configured');this.chunks.push(chunk);}
  }
  class Socket {
    constructor(url){this.url=url;this.readyState=1;this.sent=[];ws=this;}
    close(){this.readyState=3;}
    send(data){this.sent.push(data);}
  }
  vm.runInNewContext(script, {screen,token:'secret',message(){},document:{getElementById:id=>elements[id]},
    window:{...(supported?{VideoDecoder:Decoder}:{}),addEventListener(){}},VideoDecoder:Decoder,WebSocket:Socket,
    EncodedVideoChunk:class {constructor(options){Object.assign(this,options);}},performance:{now:()=>now},
    location:{host:'127.0.0.1:8765',reload(){}},setInterval:fn=>timer=fn,DataView,Uint8Array,encodeURIComponent});
  function config(w=1178,h=2556){ws.onmessage({data:JSON.stringify({type:'config',codec:'avc1.640034',width:w,height:h})});}
  function packet(key){const data=new ArrayBuffer(13),view=new DataView(data);view.setUint8(0,key?1:0);view.setBigUint64(1,123456n);ws.onmessage({data});}
  return {elements,screen,get ws(){return ws;},get vd(){return vd;},config,packet,
    output(){vd.callbacks.output({displayWidth:1178,displayHeight:2556,close(){closed++;}});},
    time(value){now=value;timer();},get drawn(){return drawn;},get closed(){return closed;}};
}
const normal=setup();normal.config();normal.packet(false);assert.equal(normal.vd.chunks.length,0);
normal.packet(true);normal.output();assert.equal(normal.vd.chunks.length,1);assert.equal(normal.vd.chunks[0].timestamp,123456);
assert.equal(normal.screen.naturalWidth,1178);assert.equal(normal.elements.video.hidden,false);assert.equal(normal.drawn,normal.closed);
normal.vd.decodeQueueSize=3;normal.packet(false);assert.deepEqual(normal.ws.sent,['keyframe']);assert.equal(normal.vd.chunks.length,1);
normal.packet(false);assert.equal(normal.vd.chunks.length,1);normal.packet(true);assert.equal(normal.vd.chunks.length,2);
normal.config(2556,1178);normal.packet(false);assert.equal(normal.vd.chunks.length,2);normal.packet(true);assert.equal(normal.vd.chunks.length,3);
normal.vd.callbacks.error();assert.equal(normal.elements.fallback.src,'/stream.mjpeg');assert.equal(normal.vd.state,'closed');assert.equal(normal.ws.readyState,3);
const missing=setup(false);assert.equal(missing.elements.fallback.src,'/stream.mjpeg');
missing.elements.fallback.naturalWidth=590;missing.elements.fallback.naturalHeight=1280;missing.time(500);assert.equal(missing.screen.naturalWidth,590);
missing.elements.fallback.listeners.error();missing.time(1000);assert.equal(missing.screen.naturalWidth,0);assert.equal(missing.elements.connection.dataset.live,'false');
const stalled=setup();stalled.time(5100);assert.equal(stalled.elements.fallback.src,'/stream.mjpeg');
console.log('Web player: decode, frame cleanup, keyframe recovery, resize, unsupported/error/stall fallback passed');
