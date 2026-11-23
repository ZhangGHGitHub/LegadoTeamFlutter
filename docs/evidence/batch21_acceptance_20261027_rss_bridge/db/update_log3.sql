UPDATE rssSources SET preloadJs='java.log(''BRIDGE_LOG'');
java.toast(''BRIDGE_TOAST'');
try { __lgChannel.request(''__action'', JSON.stringify({action:''log'',message:''DIRECT_CHANNEL''}), ''qa-direct-action''); window.__qaDirect=''sent''; } catch(e) { window.__qaDirect=''ERR ''+e; }
try { __lgEmitAction({action:''log'',message:''DIRECT_EMIT''}); window.__qaDirect=(window.__qaDirect||'''')+'' emit''; } catch(e) { window.__qaDirect=''ERR2 ''+e; }
document.addEventListener(''DOMContentLoaded'',function(){var p=document.createElement(''p'');p.id=''qa-direct'';p.textContent=''DIRECT=''+(window.__qaDirect||''none'');document.body.appendChild(p);});
document.title=''LOG'';' WHERE sourceName='QA21-日志';
