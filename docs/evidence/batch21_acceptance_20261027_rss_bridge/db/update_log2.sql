UPDATE rssSources SET preloadJs='java.log(''BRIDGE_LOG'');
java.toast(''BRIDGE_TOAST'');
document.addEventListener(''DOMContentLoaded'',function(){document.body.insertAdjacentHTML(''beforeend'',''<p id="qa-log-pre">PRELOAD_TITLE=''+document.title+'' EMIT=''+typeof __lgEmitAction+'' CHAN_NULL=''+(__lgChannel===null)+''</p>'');});
document.title=''LOG'';' WHERE sourceName='QA21-日志';
