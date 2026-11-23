BEGIN;
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=log', 'QA22-日志', 'QA批21h', '', 1, NULL, 1, 1, 'java.log(''BRIDGE_LOG'');
setTimeout(function(){ java.toast(''BRIDGE_TOAST''); }, 1200);
setTimeout(function(){ java.longToast(''BRIDGE_LONG''); }, 3200);
setTimeout(function(){ java.open(''__qa_noop'', '''', '''', ''''); }, 5200);
document.title = ''LOG21H'';', NULL, NULL, 1, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=sec', 'QA22-安全', 'QA批21h', '', 1, '{"User-Agent": "LegadoQA/21hBridge", "X-QA-Header": "QA_SECRET_21"}', 1, 1, 'document.title=''SEC'';', '(function(){
 function qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
 var all = Object.getOwnPropertyNames(window);
 var names = all.filter(function(n){return /legado/i.test(n);});
 function count(prefix){var c=0;for(var i=0;i<all.length;i++){if(all[i].indexOf(prefix)===0)c++;}return c;}
 var scripts = Array.prototype.map.call(document.scripts, function(s){return s.textContent||'''';}).join(''\n'');
 var tokens = [''QA_SECRET_21'',''LOGIN_SECRET_21'',''SECRET_VAR_21''];
 var leaks = tokens.filter(function(k){return scripts.indexOf(k)>=0;});
 qa(''qa-sec-names'',''NAMES=[''+names.join('','')+'']'');
 qa(''qa-sec-prefix'',''RN=''+count(''__rn_'')+'' RS=''+count(''__rs_'')+'' RK=''+count(''__rk_'')+'' RB=''+count(''__rb_'')+'' RC=''+count(''__rc_''));
 qa(''qa-sec-leak'',''LEAKS=[''+leaks.join('','')+''] SCRIPTCOUNT=''+document.scripts.length);
 qa(''qa-sec-title'',''TITLE=''+document.title);
})();', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=clean', 'QA22-清洗', 'QA批21h', '', 1, NULL, 1, 1, 'document.title=''SAFE'';', 'function qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
qa(''qa-clean'',''TITLE=''+document.title+'' URL=''+location.href+'' IMGS=''+document.querySelectorAll(''img'').length+'' SCRIPTS=''+document.scripts.length);', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=bridge', 'QA22-桥基础', 'QA批21h', '', 1, NULL, 1, 1, 'var t = [];
t.push(java.getTag ? ''tag='' + java.getTag() : ''no-tag'');
t.push(''src='' + source.getKey());
source.put(''k'',''v1''); t.push(''put='' + source.get(''k''));
cache.put(''ck'',''cv1''); t.push(''cache='' + cache.get(''ck''));
t.push(''b64='' + java.base64Encode(''中文''));
t.push(''md5='' + java.md5Encode(''abc''));
document.title = ''BRIDGE|'' + t.join(''|'');', 'document.body.dataset.injected=''1'';
document.body.dataset.java=typeof java;
function qa(id,text){var p=document.createElement(''p'');p.id=id;p.textContent=text;document.body.appendChild(p);}
qa(''qa-inject'',''INJECTED=''+document.body.dataset.injected+'' JAVA=''+document.body.dataset.java+'' SRC=''+typeof source+'' CACHE=''+typeof cache);
qa(''qa-title'',''TITLE=''+document.title);
qa(''qa-href'',''URL=''+location.href);', NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO rssSources (sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, singleUrl, articleStyle, customOrder) VALUES ('http://192.168.100.52:18082/rss_bridge.xml?s=normal', 'QA22-普通', 'QA批21h', '', 1, NULL, 1, 1, NULL, NULL, NULL, 0, 0, 0, 0);
INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ('loginHeader_http://192.168.100.52:18082/rss_bridge.xml?s=sec', '{"Cookie": "LOGIN_SECRET_21=1"}', 0, CAST(strftime('%s','now') AS INTEGER) * 1000);
INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ('sourceVariable_http://192.168.100.52:18082/rss_bridge.xml?s=sec', 'SECRET_VAR_21', 0, CAST(strftime('%s','now') AS INTEGER) * 1000);
COMMIT;
