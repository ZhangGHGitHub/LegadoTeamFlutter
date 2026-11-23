BEGIN;
UPDATE rssSources SET injectJs='java.log(''BRIDGE_LOG_INJECT'');
document.body.insertAdjacentHTML(''beforeend'',''<p id="qa-log-inject">JAVA_LOG_TYPE=''+typeof java.log+'' TITLE=''+document.title+''</p>'');' WHERE sourceName='QA21-日志';
UPDATE rssSources SET preloadJs='function __qa0(id,text){function go(){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener(''DOMContentLoaded'',go);}}
__qa0(''qa-java-ajaxawait'',''JAVA_AJAXAWAIT=''+typeof java.ajaxAwait);
function __qa(id,text){function go(){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener(''DOMContentLoaded'',go);}}
__qa(''qa-url-src'',''SRC=''+source.getKey());
ajaxAwait(''http://192.168.100.52:18082/echo?from=urlmode'','''',9000).then(function(r){__qa(''aw-url-body'',''AW-BODY ''+(r && r.body));__qa(''aw-url-raw'',''AW-RAW ''+String(r));document.title=''URLBRIDGE|''+(r && r.body ? r.body : String(r));},function(e){__qa(''aw-url-err'',''ERR ''+e);});' WHERE sourceName='QA21-URL模式';
COMMIT;
