extension WebPreviewServer {
    static let page = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="phoneuse-token" content="CONTROL_TOKEN">
    <title>PhoneUse</title><style>
    :root{color-scheme:dark;font:13px system-ui;background:#101114;color:#dce0e7}
    *{box-sizing:border-box}body{margin:0;min-height:100dvh;display:flex;flex-direction:column;align-items:center}
    header{height:40px;width:100%;padding:0 20px;display:flex;align-items:center;justify-content:space-between;color:#8e95a3;font-size:12px}
    header span:first-child{font-weight:600;letter-spacing:.04em}#connection{display:flex;align-items:center;gap:6px}
    #connection:before{content:'';width:5px;height:5px;border-radius:50%;background:#7b8290}
    #connection[data-live=true]:before{background:#65cf9b}
    main{flex:1;min-height:0;display:grid;place-items:center;width:100%;padding:4px 16px}
    #screen{--aspect:.46;width:min(calc(100vw - 32px),calc((100dvh - 132px)*var(--aspect)));aspect-ratio:var(--aspect);position:relative;
      border-radius:12px;overflow:hidden;background:#060709;box-shadow:0 12px 50px #0005;touch-action:none;user-select:none;cursor:crosshair}
    canvas,img{display:block;width:100%;height:100%} [hidden]{display:none!important}
    nav{display:flex;justify-content:center;align-items:center;gap:4px;padding:8px;border:1px solid #ffffff0d;background:#1a1c21;border-radius:14px;margin-top:12px}
    button{border:0;background:transparent;color:#bec5d0;border-radius:8px;height:34px;min-width:40px;padding:0 12px;font:inherit;cursor:pointer}
    button:hover{background:#ffffff0c;color:#fff}button:active{background:#ffffff16}button:focus-visible{outline:2px solid #9dbaf9;outline-offset:2px}
    button:disabled{opacity:.4;cursor:wait}.divider{height:18px;width:1px;background:#ffffff12;margin:0 4px}
    #status{height:24px;line-height:24px;margin:0;color:#7e8796;font-size:11px}#status[data-error=true]{color:#f7a99b}
    @media(max-width:380px){nav{gap:0;padding:6px}button{padding:0 9px;min-width:34px}}
    </style><header><span>PhoneUse</span><span id="connection">连接中</span></header>
    <main><div id="screen" aria-label="手机画面：点击、长按或拖动操作" title="点击、长按或拖动；Esc 取消">
    <canvas id="video" hidden></canvas><img id="fallback" alt="手机画面" draggable="false" hidden>
    </div></main>
    <nav aria-label="设备按键">
    <button data-button="back" ANDROID_HIDDEN title="返回">返回</button>
    <button data-button="home" title="主屏幕">Home</button>
    <button data-button="app_switch" ANDROID_HIDDEN title="多任务">多任务</button><span class="divider"></span>
    <button data-button="volume_down" aria-label="减小音量" title="减小音量">音量 −</button>
    <button data-button="volume_up" aria-label="增大音量" title="增大音量">＋</button>
    <button data-button="lock" title="锁屏 / 唤醒">锁屏</button><span class="divider"></span>
    <button id="reconnect" aria-label="重新连接" title="重新连接">↻</button></nav>
    <p id="status" role="status" aria-live="polite"></p><script id="controls">
    const screen = document.getElementById('screen');
    const status = document.getElementById('status');
    const buttons = [...document.querySelectorAll('button[data-button]')];
    const token = document.querySelector('meta[name="phoneuse-token"]').content;
    let busy = false, gesture = null;
    function message(text, error = false) { status.textContent = text; status.dataset.error = String(error); }
    async function send(command) {
      if (busy) return;
      busy = true; buttons.forEach(button => button.disabled = true); message('操作中…');
      try {
        const response = await fetch('/input', {method:'POST', headers:{'Content-Type':'application/json','X-PhoneUse-Token':token},body:JSON.stringify(command)});
        const result = await response.json();
        if (!response.ok) throw new Error(result.error || '操作失败');
        message('');
      } catch (error) { message(error.message + '（未自动重试）', true); }
      finally { busy = false; buttons.forEach(button => button.disabled = false); }
    }
    function point(event) {
      const bounds = screen.getBoundingClientRect();
      return {x:Math.max(0,Math.min(1,(event.clientX-bounds.left)/bounds.width)),
              y:Math.max(0,Math.min(1,(event.clientY-bounds.top)/bounds.height))};
    }
    screen.addEventListener('pointerdown', event => {
      if (busy || gesture || event.button !== 0 || !event.isPrimary || !screen.naturalWidth) return;
      event.preventDefault(); screen.setPointerCapture(event.pointerId);
      gesture = {id:event.pointerId, start:point(event), at:performance.now(),
                 clientX:event.clientX, clientY:event.clientY, moved:false,
                 aspect:screen.naturalWidth/screen.naturalHeight};
      message('松开后执行；Esc 取消');
    });
    screen.addEventListener('pointermove', event => {
      if (gesture?.id !== event.pointerId) return;
      if (Math.hypot(event.clientX-gesture.clientX,event.clientY-gesture.clientY) > 8) gesture.moved = true;
    });
    screen.addEventListener('pointerup', event => {
      if (gesture?.id !== event.pointerId) return;
      const held = gesture, end = point(event); gesture = null;
      screen.releasePointerCapture(event.pointerId);
      if (Math.abs((screen.naturalWidth/screen.naturalHeight)/held.aspect-1) > .03) { message('画面方向已变化，请重新操作',true); return; }
      const duration = Math.max(50,Math.min(2000,Math.round(performance.now()-held.at)));
      const base = {...held.start, aspect:held.aspect};
      if (held.moved || Math.hypot(event.clientX-held.clientX,event.clientY-held.clientY) > 8)
        send({...base, action:'swipe',toX:end.x,toY:end.y,duration});
      else if (duration >= 500) send({...base,action:'longpress',duration});
      else send({...base,action:'tap'});
    });
    function cancelGesture() {
      const held = gesture; gesture = null;
      if (held) { if (screen.hasPointerCapture(held.id)) screen.releasePointerCapture(held.id); message('已取消'); }
    }
    screen.addEventListener('pointercancel', cancelGesture);
    screen.addEventListener('lostpointercapture', cancelGesture);
    screen.addEventListener('contextmenu', event => event.preventDefault());
    window.addEventListener('blur', cancelGesture);
    window.addEventListener('keydown', event => { if (event.key === 'Escape') cancelGesture(); });
    buttons.forEach(button => button.addEventListener('click', () => send({action:'press',button:button.dataset.button})));
    </script><script id="player">
    const canvas = document.getElementById('video'), fallback = document.getElementById('fallback');
    const connection = document.getElementById('connection');
    let socket = null, decoder = null, config = null, waitingKey = true, usingFallback = false, fallbackFailed = false;
    let frameWidth = 0, frameHeight = 0, lastFrameAt = performance.now();
    Object.defineProperties(screen, {naturalWidth:{get:()=>frameWidth}, naturalHeight:{get:()=>frameHeight}});
    const drawing = canvas.getContext('2d', {alpha:false, desynchronized:true});
    function dimensions(width,height) {
      frameWidth=width; frameHeight=height; screen.style.setProperty('--aspect',String(width/height));
    }
    function live(text) { connection.textContent=text; connection.dataset.live='true'; }
    function stopVideo() {
      if(socket) { socket.onclose=null; socket.onerror=null; socket.onmessage=null; socket.close(); socket=null; }
      if(decoder && decoder.state !== 'closed') decoder.close();
      decoder=null;
    }
    function useFallback() {
      if(usingFallback) return;
      usingFallback=true; stopVideo(); canvas.hidden=true; fallback.hidden=false;
      frameWidth=0; frameHeight=0;
      fallback.src='/stream.mjpeg'; connection.textContent='等待手机画面'; connection.dataset.live='false';
    }
    // Multipart images do not consistently dispatch load for every frame across browsers.
    setInterval(()=> {
      if(usingFallback && !fallbackFailed && fallback.naturalWidth) {
        dimensions(fallback.naturalWidth,fallback.naturalHeight); live('已连接');
      } else if(!usingFallback && performance.now()-lastFrameAt > 5000) useFallback();
    },500);
    fallback.addEventListener('error',()=>{fallbackFailed=true;frameWidth=0;frameHeight=0;connection.textContent='连接已断开';connection.dataset.live='false';message('点击 ↻ 重新连接',true);});
    document.getElementById('reconnect').addEventListener('click',()=>location.reload());
    function recover() {
      waitingKey=true;
      if(decoder?.state === 'configured') { decoder.reset(); decoder.configure(config); }
      if(socket?.readyState === 1) socket.send('keyframe');
    }
    if(!('VideoDecoder' in window) || !drawing) useFallback();
    else {
      try {
        decoder=new VideoDecoder({
          output(frame) {
            try {
              if(canvas.width!==frame.displayWidth || canvas.height!==frame.displayHeight) {
                canvas.width=frame.displayWidth; canvas.height=frame.displayHeight;
              }
              drawing.drawImage(frame,0,0,canvas.width,canvas.height);
              dimensions(canvas.width,canvas.height); canvas.hidden=false; fallback.hidden=true;
              lastFrameAt=performance.now(); live('已连接');
            } finally { frame.close(); }
          },
          error:useFallback
        });
        socket=new WebSocket('ws://'+location.host+'/video?token='+encodeURIComponent(token)); socket.binaryType='arraybuffer';
        socket.onclose=useFallback; socket.onerror=useFallback;
        socket.onmessage=event=> {
          try {
            if(typeof event.data === 'string') {
              const next=JSON.parse(event.data);
              if(next.type!=='config') return;
              if(!config || config.codec!==next.codec || config.codedWidth!==next.width || config.codedHeight!==next.height) {
                config={codec:next.codec,codedWidth:next.width,codedHeight:next.height,optimizeForLatency:true};
                decoder.reset(); decoder.configure(config); waitingKey=true;
              }
              return;
            }
            if(!config || event.data.byteLength<=9) return;
            const view=new DataView(event.data), key=view.getUint8(0)===1;
            if(decoder.decodeQueueSize>2) recover();
            if(waitingKey && !key) return;
            waitingKey=false;
            decoder.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:Number(view.getBigUint64(1)),data:new Uint8Array(event.data,9)}));
          } catch { useFallback(); }
        };
      } catch { useFallback(); }
    }
    window.addEventListener('pagehide',stopVideo);
    </script></html>
    """
}
