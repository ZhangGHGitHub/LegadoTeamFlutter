// ⚡📂77读书（http://www.77shuku.info）搜索规则 verbatim 夹具
// 来源：语料 .tmp/corpus/yckceo_1283.json index 6 的 ruleSearch.bookList
// （`@js:` 前缀之后的原文，未做任何改写；提取时间 2026-09-25）。
//
// 该规则依赖 jsoup `Elements` 集合 API（rows.size() / rows.get(i)）与
// 行作用域内 `td.get(n)` 索引访问；修复前 JSOUP_BRIDGE_JS 的 Elements
// 模拟层无集合 API，`rows.size()` 抛 `not a function`（<input>:1:246），
// 整条搜索规则失败。本夹具用于 e2e 红→绿验证。
var Jsoup = Packages.org.jsoup.Jsoup; var doc = (result && typeof result.select === 'function') ? result : Jsoup.parse(String(result)); function E(s){ return String(s).trim(); } var out = []; var rows = doc.select('tr'); for (var i = 0; i < rows.size(); i++) { var td = rows.get(i).select('td'); if (td.size() < 7) { continue; } var a = td.get(2).select('a'); if (a.size() == 0) { continue; } var url = String(a.get(0).attr('href')); if (url.indexOf('/novel/') < 0) { continue; } var name = E(a.get(0).text()); var auEl = td.get(5).select('span'); var author = auEl.size() > 0 ? E(auEl.get(0).text()) : E(td.get(5).text()); var kindS = E(td.get(1).text()).replace('[', '').replace(']', ''); var ch = td.get(3).select('a'); var last = ch.size() > 0 ? E(ch.get(0).text()) : ''; var wc = ''; if (td.size() > 7) { wc = E(td.get(7).text()); if (wc.indexOf('K') > -1) { wc = wc.split('K').join('000'); } } out.push(String(JSON.stringify({name: name, bookUrl: url, author: author, kind: kindS, lastChapter: last, wordCount: wc, intro: ''}))); } out;
