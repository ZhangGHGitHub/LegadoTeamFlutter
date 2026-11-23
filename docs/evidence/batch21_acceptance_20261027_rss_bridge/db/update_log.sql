UPDATE rssSources SET preloadJs='java.log(''BRIDGE_LOG'');
document.addEventListener(''DOMContentLoaded'',function(){document.body.insertAdjacentHTML(''beforeend'',''<p id="qa-log-pre">PRELOAD_TITLE=''+document.title+''</p>'');});
document.title=''LOG'';' WHERE sourceName='QA21-日志';
