BEGIN;
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=bridge', 'QA21-桥基础', 'QA批21', '', 1, NULL, 1, 1, 'var t = [];
t.push(java.getTag ? ''tag='' + java.getTag() : ''no-tag'');
t.push(''src='' + source.getKey());
source.put(''k'',''v1''); t.push(''put='' + source.get(''k''));
cache.put(''ck'',''cv1''); t.push(''cache='' + cache.get(''ck''));
t.push(''b64='' + java.base64Encode(''中文''));
t.push(''md5='' + java.md5Encode(''abc''));
document.title = ''BRIDGE|'' + t.join(''|'');', 'document.body.dataset.injected=''1'';
document.body.dataset.java=typeof java;
function __qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa(''qa-inject'',''INJECTED=''+document.body.dataset.injected+'' JAVA=''+document.body.dataset.java+'' SRC=''+typeof source+'' CACHE=''+typeof cache);
__qa(''qa-title'',''TITLE=''+document.title);
__qa(''qa-href'',''URL=''+location.href);', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=clean', 'QA21-清洗', 'QA批21', '', 1, NULL, 1, 1, 'document.title=''SAFE'';', 'function __qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa(''qa-clean'',''TITLE=''+document.title+'' URL=''+location.href+'' IMGS=''+document.querySelectorAll(''img'').length+'' SCRIPTS=''+document.scripts.length);', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=normal', 'QA21-普通', 'QA批21', '', 1, NULL, 1, 1, NULL, NULL, NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=sec', 'QA21-安全', 'QA批21', '', 1, '{"User-Agent": "LegadoQA/21Bridge", "X-QA-Header": "QA_SECRET_21"}', 1, 1, 'document.title=''SEC'';', '(function(){
 function __qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
 var names = Object.getOwnPropertyNames(window).filter(function(n){return /legado/i.test(n);});
 var chans = names.filter(function(n){return /rssNative/i.test(n);});
 var scripts = Array.prototype.map.call(document.scripts, function(s){return s.textContent||'''';}).join(''\n'');
 var tokens = [''QA_SECRET_21'',''LOGIN_SECRET_21'',''SECRET_VAR_21''];
 var leaks = tokens.filter(function(k){return scripts.indexOf(k)>=0;});
 __qa(''qa-sec'',''NAMES=[''+names.join('','')+'']'');
 __qa(''qa-sec-chan'',''CHAN=[''+chans.join('','')+'']'');
 __qa(''qa-sec-leak'',''LEAKS=[''+leaks.join('','')+''] SCRIPTCOUNT=''+document.scripts.length);
 __qa(''qa-sec-title'',''TITLE=''+document.title);
})();', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/urlmode.html', 'QA21-URL模式', 'QA批21', '', 1, NULL, 1, 1, 'function __qa(id,text){function go(){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener(''DOMContentLoaded'',go);}}
__qa(''qa-url-src'',''SRC=''+source.getKey());
ajaxAwait(''http://192.168.100.52:18082/echo?from=urlmode'','''',9000).then(function(r){__qa(''aw-url-body'',''AW-BODY ''+(r && r.body));__qa(''aw-url-raw'',''AW-RAW ''+String(r));document.title=''URLBRIDGE|''+(r && r.body ? r.body : String(r));},function(e){__qa(''aw-url-err'',''ERR ''+e);});', NULL, NULL, 0, 1, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=override', 'QA21-拦截', 'QA批21', '', 1, NULL, 1, 1, 'document.title=''OVERRIDE'';', 'function __qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa(''qa-override'',''TITLE=''+document.title+'' JAVA_K=''+((window.__legadoJava&&window.__legadoJava.get)?window.__legadoJava.get(''k''):''(no-stub)''));', 'java.get(''k'')==''v1''', 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=log', 'QA21-日志', 'QA批21', '', 1, NULL, 1, 1, 'java.log(''BRIDGE_LOG''); document.title=''LOG'';', NULL, NULL, 1, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=ajax', 'QA21-AJAX', 'QA批21', '', 1, NULL, 1, 1, 'function __qa(id,text){function go(){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener(''DOMContentLoaded'',go);}}
ajaxAwait(''http://192.168.100.52:18082/echo'','''',9000).then(function(r){__qa(''aw'',''AW-BODY ''+(r && r.body));__qa(''aw-raw'',''AW-RAW ''+String(r));document.title=''AJAX|''+String(r);},function(e){__qa(''aw-err'',''ERR ''+e);});', NULL, NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ('loginHeader_http://192.168.100.52:18082/rss_bridge.xml?s=sec', '{"Cookie": "LOGIN_SECRET_21=1"}', 0, CAST(strftime('%s','now') AS INTEGER) * 1000);
INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ('sourceVariable_http://192.168.100.52:18082/rss_bridge.xml?s=sec', 'SECRET_VAR_21', 0, CAST(strftime('%s','now') AS INTEGER) * 1000);
INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ('v_http://192.168.100.52:18082/rss_bridge.xml?s=override_k', 'v1', 0, CAST(strftime('%s','now') AS INTEGER) * 1000);
COMMIT;
