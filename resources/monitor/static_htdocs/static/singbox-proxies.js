// Sing-box: список прокси (outbound'ы) на странице настроек — показ ссылок, удаление, добавление из ссылок

const SINGBOX_CONFIG_GET  = '/cgi-bin/config.cgi/sing-box/config/full';
const SINGBOX_CONFIG_POST = '/cgi-bin/config.cgi/sing-box/config/full';
const SINGBOX_PROXY_MAX   = 10;
const SELECTOR_TAG        = 'allow-proxy';
const URLTEST_TAG         = 'allow-urltest';
const URLTEST_URL         = 'https://www.gstatic.com/generate_204';
const URLTEST_INTERVAL    = '3m';
const URLTEST_TOLERANCE   = 50;
const CLASH_API_DEFAULT   = '127.0.0.1:9090';

let singboxCurrentConfig = null;  // { config, proxyOutbounds, directBlock }
let singboxProxyLinks    = [];    // ссылки для отображения (индексы совпадают с proxyOutbounds)
let singboxDirty         = false; // черновик изменён, нужна отправка по «Сохранить»

function outboundToLink(outbound) {
    if (!outbound || !outbound.type) return null;
    try {
        if (outbound.type === 'vmess' && typeof convertToVmess === 'function') return convertToVmess(outbound);
        if (outbound.type === 'vless' && typeof convertToVless === 'function') return convertToVless(outbound);
        if (outbound.type === 'trojan' && typeof convertToTrojan === 'function') return convertToTrojan(outbound);
        if (outbound.type === 'hysteria2' && typeof convertToHysteria2 === 'function') return convertToHysteria2(outbound);
        if (outbound.type === 'shadowsocks' && typeof convertToShadowsocks === 'function') return convertToShadowsocks(outbound);
    } catch (e) {
        console.warn('outboundToLink:', e);
    }
    return null;
}

/** Удаляет управляющие символы (U+0000–U+001F, U+007F) из строк в объекте (рекурсивно), в т.ч. из ключей. */
function stripControlChars(obj) {
    if (obj === null || typeof obj !== 'object') return obj;
    if (Array.isArray(obj)) {
        return obj.map(function (item) { return stripControlChars(item); });
    }
    var out = {};
    for (var key in obj) {
        if (!Object.prototype.hasOwnProperty.call(obj, key)) continue;
        var cleanKey = typeof key === 'string' ? key.replace(/[\x00-\x1f\x7f]/g, '') : key;
        var val = obj[key];
        if (typeof val === 'string') {
            out[cleanKey] = val.replace(/[\x00-\x1f\x7f]/g, '');
        } else {
            out[cleanKey] = stripControlChars(val);
        }
    }
    return out;
}

/** Удаляет управляющие и нежелательные символы из JSON-строки (в т.ч. U+2028/U+2029). */
function stripControlCharsFromJsonString(str) {
    if (typeof str !== 'string') return str;
    return str.replace(/[\x00-\x1f\x7f\u2028\u2029]/g, '');
}

/** Дебаг: вывести в console длину строки и коды символов вокруг позиции 26. Вызывать при ошибке или если window.SINGBOX_DEBUG=1. */
function singboxDebugConfigStr(label, str) {
    if (typeof window !== 'undefined' && !window.SINGBOX_DEBUG && !window._singboxLastDebug) return;
    if (typeof str !== 'string') return;
    var len = str.length;
    var slice = [];
    for (var i = Math.max(0, 20); i < Math.min(len, 45); i++) {
        var c = str.charAt(i);
        slice.push(i + ':' + c.charCodeAt(0) + '(' + (c.charCodeAt(0) < 32 ? 'ctrl' : c.replace(/\\/g, '\\\\').replace(/"/g, '\\"')) + ')');
    }
    console.log('[singbox debug] ' + label + ' len=' + len + ' around pos 20-44: ' + slice.join(' '));
}

/** Удаляет поля, неподдерживаемые старыми версиями sing-box (например tls.record_fragment). */
function stripUnsupportedSingboxOutboundFields(config) {
    if (!config || !Array.isArray(config.outbounds)) return;
    config.outbounds.forEach(function (o) {
        if (o && o.tls && typeof o.tls === 'object' && Object.prototype.hasOwnProperty.call(o.tls, 'record_fragment')) {
            delete o.tls.record_fragment;
        }
    });
}

/** Устанавливает config.route.final: при 2+ прокси — selector (allow-proxy), иначе первый прокси или direct. */
function applySingboxRouteFinal(config, proxyOutbounds) {
    if (!config) return;
    if (!config.route || typeof config.route !== 'object') config.route = {};
    if (proxyOutbounds.length >= 2) {
        config.route.final = SELECTOR_TAG;
    } else {
        config.route.final = proxyOutbounds.length > 0 ? proxyOutbounds[0].tag : 'direct';
    }
}

/** Присваивает стабильные теги proxy-1, proxy-2, ... при 2+ прокси. */
function ensureProxyTags(proxyOutbounds) {
    if (!proxyOutbounds || proxyOutbounds.length < 2) return;
    proxyOutbounds.forEach(function (o, i) {
        if (o && (o.type === 'vless' || o.type === 'trojan' || o.type === 'vmess' || o.type === 'shadowsocks' || o.type === 'hysteria2')) {
            o.tag = 'proxy-' + (i + 1);
        }
    });
}

/** Добавляет experimental.clash_api в config, если его ещё нет (нужно для переключения в UI). */
function ensureClashApi(config) {
    if (!config) return;
    if (!config.experimental || typeof config.experimental !== 'object') config.experimental = {};
    if (!config.experimental.clash_api || !config.experimental.clash_api.external_controller) {
        config.experimental.clash_api = {
            external_controller: CLASH_API_DEFAULT
        };
    }
}

/** Читает параметры URLTest из полей формы или возвращает значения по умолчанию. */
function getUrltestOptionsFromDom() {
    var urlEl = document.getElementById('singbox-urltest-url');
    var intervalEl = document.getElementById('singbox-urltest-interval');
    var toleranceEl = document.getElementById('singbox-urltest-tolerance');
    var url = (urlEl && urlEl.value && urlEl.value.trim()) ? urlEl.value.trim() : URLTEST_URL;
    var interval = (intervalEl && intervalEl.value && intervalEl.value.trim()) ? intervalEl.value.trim() : URLTEST_INTERVAL;
    var t = (toleranceEl && toleranceEl.value !== '' && toleranceEl.value !== undefined) ? parseInt(toleranceEl.value, 10) : NaN;
    var tolerance = (!isNaN(t) && t >= 0) ? t : URLTEST_TOLERANCE;
    return { url: url, interval: interval, tolerance: tolerance };
}

/** Показать/заполнить блок «Параметры URLTest» при 2+ прокси. */
function renderUrltestOptions() {
    var block = document.getElementById('singbox-urltest-options');
    if (!block) return;
    if (!singboxCurrentConfig || !singboxCurrentConfig.proxyOutbounds || singboxCurrentConfig.proxyOutbounds.length < 2) {
        block.style.display = 'none';
        return;
    }
    block.style.display = 'block';
    var opts = singboxCurrentConfig.urltestOptions || { url: URLTEST_URL, interval: URLTEST_INTERVAL, tolerance: URLTEST_TOLERANCE };
    var urlEl = document.getElementById('singbox-urltest-url');
    var intervalEl = document.getElementById('singbox-urltest-interval');
    var toleranceEl = document.getElementById('singbox-urltest-tolerance');
    if (urlEl) urlEl.value = opts.url || URLTEST_URL;
    if (intervalEl) intervalEl.value = opts.interval || URLTEST_INTERVAL;
    if (toleranceEl) toleranceEl.value = String(opts.tolerance !== undefined && opts.tolerance !== null ? opts.tolerance : URLTEST_TOLERANCE);
}

/** Собирает массив outbounds: при 1 прокси — [proxy, ...directBlock]; при 2+ — directBlock, прокси, urltest, selector. */
function buildOutboundsArray(proxyOutbounds, directBlock) {
    var list = [];
    if (!proxyOutbounds || proxyOutbounds.length === 0) {
        return (directBlock || []).map(stripControlChars);
    }
    if (proxyOutbounds.length === 1) {
        list = [stripControlChars(proxyOutbounds[0])].concat((directBlock || []).map(stripControlChars));
        return list;
    }
    ensureProxyTags(proxyOutbounds);
    var proxyTags = proxyOutbounds.map(function (o) { return o.tag; });
    var directPart = (directBlock || []).map(stripControlChars);
    var proxyPart = proxyOutbounds.map(function (o) { return stripControlChars(o); });
    var opts = getUrltestOptionsFromDom();
    var urltestPart = {
        type: 'urltest',
        tag: URLTEST_TAG,
        outbounds: proxyTags,
        url: opts.url,
        interval: opts.interval,
        tolerance: opts.tolerance
    };
    var selectorPart = {
        type: 'selector',
        tag: SELECTOR_TAG,
        outbounds: [URLTEST_TAG].concat(proxyTags),
        default: URLTEST_TAG
    };
    list = directPart.concat(proxyPart, [urltestPart], [selectorPart]);
    return list;
}

function parseConfigFromResponse(data) {
    const configLines = data.config;
    if (!Array.isArray(configLines)) return null;
    var configStr = configLines.map(function (line) {
        return typeof line === 'string' ? line.replace(/\r?\n$/, '') : String(line);
    }).join('\n');
    configStr = stripControlCharsFromJsonString(configStr);
    try {
        return JSON.parse(configStr);
    } catch (e) {
        return null;
    }
}

function renderSingboxProxyList() {
    const listEl = document.getElementById('singbox-proxy-list');
    const hintEl = document.getElementById('singbox-proxy-list-hint');
    if (!listEl) return;

    listEl.innerHTML = '';
    if (!singboxProxyLinks.length) {
        listEl.innerHTML = '<p style="color: #6e6e73; margin: 0;">Нет прокси-outbound\'ов в конфиге.</p>';
        if (hintEl) hintEl.textContent = '';
        return;
    }

    const fragment = document.createDocumentFragment();
    singboxProxyLinks.forEach(function (link, index) {
        const num = index + 1;
        const row = document.createElement('div');
        row.className = 'singbox-proxy-row';
        const label = document.createElement('span');
        label.className = 'singbox-proxy-num';
        label.textContent = num + '.';
        const linkSpan = document.createElement('span');
        linkSpan.className = 'singbox-proxy-link';
        linkSpan.textContent = link.length > 80 ? link.substring(0, 80) + '…' : link;
        linkSpan.title = link;
        const copyBtn = document.createElement('button');
        copyBtn.type = 'button';
        copyBtn.className = 'btn btn-secondary';
        copyBtn.style.cssText = 'padding: 4px 10px; font-size: 12px;';
        copyBtn.textContent = 'Копировать';
        copyBtn.onclick = function () { copySingboxProxyLink(link); };
        const delBtn = document.createElement('button');
        delBtn.type = 'button';
        delBtn.className = 'btn btn-secondary';
        delBtn.style.cssText = 'padding: 4px 10px; font-size: 12px;';
        delBtn.textContent = 'Удалить';
        delBtn.onclick = function () { deleteSingboxProxy(index); };
        row.appendChild(label);
        row.appendChild(linkSpan);
        row.appendChild(copyBtn);
        row.appendChild(delBtn);
        fragment.appendChild(row);
    });
    listEl.appendChild(fragment);

    if (hintEl) {
        if (singboxProxyLinks.length >= SINGBOX_PROXY_MAX) {
            hintEl.textContent = 'Достигнут лимит: ' + SINGBOX_PROXY_MAX + ' прокси. Удалите один, чтобы добавить новый.';
        } else {
            hintEl.textContent = 'Прокси: ' + singboxProxyLinks.length + ' из ' + SINGBOX_PROXY_MAX + '.';
        }
    }
}

function copySingboxProxyLink(link) {
    if (!link) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(link).then(function () {
            if (typeof showToast === 'function') showToast('Ссылка скопирована');
        }).catch(function () {
            fallbackCopy(link);
        });
    } else {
        fallbackCopy(link);
    }
}

function fallbackCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    try {
        document.execCommand('copy');
        if (typeof showToast === 'function') showToast('Ссылка скопирована');
    } catch (e) {
        if (typeof showToast === 'function') showToast('Не удалось скопировать', 2000);
    }
    document.body.removeChild(ta);
}

function deleteSingboxProxy(index) {
    if (!singboxCurrentConfig || index < 0 || index >= singboxCurrentConfig.proxyOutbounds.length) return;
    const proxyOutbounds = singboxCurrentConfig.proxyOutbounds.slice();
    proxyOutbounds.splice(index, 1);
    const links = [];
    proxyOutbounds.forEach(function (o) {
        const link = outboundToLink(o);
        links.push(link || '(не удалось преобразовать в ссылку)');
    });
    applySingboxRouteFinal(singboxCurrentConfig.config, proxyOutbounds);
    singboxCurrentConfig.proxyOutbounds = proxyOutbounds;
    singboxCurrentConfig.config.outbounds = buildOutboundsArray(proxyOutbounds, singboxCurrentConfig.directBlock);
    if (proxyOutbounds.length >= 2) ensureClashApi(singboxCurrentConfig.config);
    stripUnsupportedSingboxOutboundFields(singboxCurrentConfig.config);
    singboxProxyLinks = links;
    singboxDirty = true;
    renderSingboxProxyList();
    renderUrltestOptions();
    if (typeof window.settingsUpdateSaveButton === 'function') window.settingsUpdateSaveButton();
}

async function loadSingboxProxyList() {
    const listEl = document.getElementById('singbox-proxy-list');
    if (!listEl) return;
    listEl.innerHTML = '<p style="color: #6e6e73; margin: 0;">Загрузка…</p>';
    if (typeof showProgress === 'function') showProgress('Загрузка...');
    try {
        const data = await apiRequest(SINGBOX_CONFIG_GET);
        const config = parseConfigFromResponse(data);
        if (!config || !config.outbounds || !Array.isArray(config.outbounds)) {
            singboxCurrentConfig = null;
            singboxProxyLinks = [];
            renderSingboxProxyList();
            return;
        }
        const directBlock = config.outbounds.filter(function (o) {
            return o.type === 'direct' || o.type === 'block';
        });
        var proxyOutbounds;
        var selectorOb = config.outbounds.find(function (o) { return o.type === 'selector' && o.tag === SELECTOR_TAG; });
        if (selectorOb && Array.isArray(selectorOb.outbounds)) {
            var tagOrder = selectorOb.outbounds.filter(function (tag) { return tag !== URLTEST_TAG; });
            var byTag = {};
            config.outbounds.forEach(function (o) {
                if (o && o.tag) byTag[o.tag] = o;
            });
            proxyOutbounds = tagOrder.map(function (tag) { return byTag[tag]; }).filter(Boolean).slice(0, SINGBOX_PROXY_MAX);
        } else {
            proxyOutbounds = config.outbounds.filter(function (o) {
                return o.type !== 'direct' && o.type !== 'block' && o.type !== 'selector' && o.type !== 'urltest';
            }).slice(0, SINGBOX_PROXY_MAX);
        }
        const links = [];
        proxyOutbounds.forEach(function (o) {
            const link = outboundToLink(o);
            links.push(link || '(не удалось преобразовать в ссылку)');
        });
        var urltestOb = config.outbounds.find(function (o) { return o.type === 'urltest' && o.tag === URLTEST_TAG; });
        var urltestOptions = { url: URLTEST_URL, interval: URLTEST_INTERVAL, tolerance: URLTEST_TOLERANCE };
        if (urltestOb) {
            if (urltestOb.url) urltestOptions.url = urltestOb.url;
            if (urltestOb.interval) urltestOptions.interval = urltestOb.interval;
            if (urltestOb.tolerance !== undefined && urltestOb.tolerance !== null) urltestOptions.tolerance = Number(urltestOb.tolerance);
        }
        singboxCurrentConfig = { config: config, proxyOutbounds: proxyOutbounds, directBlock: directBlock, urltestOptions: urltestOptions };
        singboxProxyLinks = links;
        singboxDirty = false;
        renderSingboxProxyList();
        renderUrltestOptions();
        loadSettingsProxySelector().catch(function () {});
    } catch (err) {
        listEl.innerHTML = '<p style="color: #c00;">Ошибка загрузки: ' + (err.message || 'сеть') + '</p>';
        singboxCurrentConfig = null;
        singboxProxyLinks = [];
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
    }
}

async function loadSettingsProxySelector() {
    var container = document.getElementById('singbox-settings-proxy-selector');
    var listEl = document.getElementById('singbox-settings-proxy-selector-list');
    var errEl = document.getElementById('singbox-settings-proxy-selector-error');
    if (!container || !listEl) return;
    if (errEl) { errEl.style.display = 'none'; errEl.textContent = ''; }
    listEl.innerHTML = '';
    container.style.display = 'none';
    try {
        var data = await apiRequest('/singbox/proxies');
        if (data && data.error) {
            if (errEl) { errEl.textContent = data.message || data.error; errEl.style.display = 'block'; }
            container.style.display = 'block';
            return;
        }
        var proxies = data && data.proxies ? data.proxies : {};
        var group = proxies[SELECTOR_TAG];
        if (!group || !Array.isArray(group.all) || group.all.length === 0) return;
        container.style.display = 'block';
        var now = group.now || '';
        group.all.forEach(function (tag) {
            var label = (tag === URLTEST_TAG) ? 'Авто' : (proxies[tag] && proxies[tag].name ? proxies[tag].name : tag);
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'btn btn-secondary singbox-proxy-option' + (tag === now ? ' singbox-proxy-option--active' : '');
            btn.textContent = label;
            btn.dataset.tag = tag;
            btn.style.cssText = 'padding: 4px 10px; font-size: 12px;';
            btn.addEventListener('click', function () {
                var t = btn.dataset.tag;
                if (!t || t === now) return;
                btn.disabled = true;
                apiRequest('/singbox/proxies', 'PUT', { group: SELECTOR_TAG, name: t })
                    .then(function () {
                        if (typeof showToast === 'function') showToast('Прокси изменён');
                        loadSettingsProxySelector().catch(function () {});
                    })
                    .catch(function (e) {
                        if (typeof showToast === 'function') showToast('Ошибка: ' + (e.message || 'сеть'), 3000);
                        loadSettingsProxySelector().catch(function () {});
                    })
                    .finally(function () { btn.disabled = false; });
            });
            listEl.appendChild(btn);
        });
    } catch (e) {
        if (errEl) { errEl.textContent = e.message || 'Не удалось загрузить список прокси'; errEl.style.display = 'block'; }
        container.style.display = 'block';
    }
}

async function singboxConvertLinksToOutbounds(inputText) {
    if (typeof extractStandardConfigs !== 'function') {
        throw new Error('Конвертер не загружен');
    }
    window.vmessCount = 0;
    window.vlessCount = 0;
    window.trojanCount = 0;
    window.hysteria2Count = 0;
    window.ssCount = 0;
    const configs = await extractStandardConfigs(inputText);
    const outbounds = [];
    configs.forEach(function (config) {
        var converted = null;
        try {
            if (config.startsWith('vmess://')) converted = typeof convertVmess === 'function' ? convertVmess(config, false, '') : null;
            else if (config.startsWith('vless://')) converted = typeof convertVless === 'function' ? convertVless(config, false, '') : null;
            else if (config.startsWith('trojan://')) converted = typeof convertTrojan === 'function' ? convertTrojan(config, false, '') : null;
            else if (config.startsWith('hysteria2://') || config.startsWith('hy2://')) converted = typeof convertHysteria2 === 'function' ? convertHysteria2(config, false, '') : null;
            else if (config.startsWith('ss://')) converted = typeof convertShadowsocks === 'function' ? convertShadowsocks(config, false, '') : null;
        } catch (e) {}
        if (converted) outbounds.push(converted);
    });
    return outbounds;
}

async function singboxSettingsAddFromLinks() {
    const inputEl = document.getElementById('singbox-settings-import-input');
    const btnEl = document.getElementById('singbox-settings-import-btn');
    const msgEl = document.getElementById('singbox-settings-import-message');
    const inputText = (inputEl && inputEl.value) ? inputEl.value.trim() : '';
    if (!inputText) {
        if (msgEl) msgEl.textContent = 'Вставьте ссылки или Base64-подписку.';
        return;
    }
    if (btnEl) btnEl.disabled = true;
    if (msgEl) msgEl.textContent = 'Преобразование…';
    if (typeof showProgress === 'function') showProgress('Преобразование...');
    try {
        const newOutbounds = await singboxConvertLinksToOutbounds(inputText);
        if (!newOutbounds.length) {
            if (msgEl) msgEl.textContent = 'Не найдено подходящих ссылок (vless, vmess, trojan, ss, hy2).';
            return;
        }
        if (!singboxCurrentConfig) {
            const data = await apiRequest(SINGBOX_CONFIG_GET);
            const config = parseConfigFromResponse(data);
            if (!config || !config.outbounds || !Array.isArray(config.outbounds)) {
                singboxCurrentConfig = { config: config || {}, proxyOutbounds: [], directBlock: config && config.outbounds ? config.outbounds.filter(function (o) { return o.type === 'direct' || o.type === 'block'; }) : [] };
                if (!config) singboxCurrentConfig.config.outbounds = [];
            } else {
                const directBlock = config.outbounds.filter(function (o) { return o.type === 'direct' || o.type === 'block'; });
                var sel = config.outbounds.find(function (o) { return o.type === 'selector' && o.tag === SELECTOR_TAG; });
                var proxyOutbounds;
                if (sel && Array.isArray(sel.outbounds)) {
                    var tagOrder = sel.outbounds.filter(function (tag) { return tag !== URLTEST_TAG; });
                    var byTag = {};
                    config.outbounds.forEach(function (o) { if (o && o.tag) byTag[o.tag] = o; });
                    proxyOutbounds = tagOrder.map(function (tag) { return byTag[tag]; }).filter(Boolean).slice(0, SINGBOX_PROXY_MAX);
                } else {
                    proxyOutbounds = config.outbounds.filter(function (o) {
                        return o.type !== 'direct' && o.type !== 'block' && o.type !== 'selector' && o.type !== 'urltest';
                    }).slice(0, SINGBOX_PROXY_MAX);
                }
                const links = [];
                proxyOutbounds.forEach(function (o) {
                    const link = outboundToLink(o);
                    links.push(link || '(не удалось преобразовать в ссылку)');
                });
                var urltestOb = config.outbounds.find(function (o) { return o.type === 'urltest' && o.tag === URLTEST_TAG; });
                var urltestOptions = { url: URLTEST_URL, interval: URLTEST_INTERVAL, tolerance: URLTEST_TOLERANCE };
                if (urltestOb) {
                    if (urltestOb.url) urltestOptions.url = urltestOb.url;
                    if (urltestOb.interval) urltestOptions.interval = urltestOb.interval;
                    if (urltestOb.tolerance !== undefined && urltestOb.tolerance !== null) urltestOptions.tolerance = Number(urltestOb.tolerance);
                }
                singboxCurrentConfig = { config: config, proxyOutbounds: proxyOutbounds, directBlock: directBlock, urltestOptions: urltestOptions };
                singboxProxyLinks = links;
            }
        }
        var existingProxies = singboxCurrentConfig.proxyOutbounds.slice();
        var combined = existingProxies.concat(newOutbounds).slice(0, SINGBOX_PROXY_MAX).map(stripControlChars);
        if (existingProxies.length === 0 && combined.length > 0 && combined[0]) {
            combined[0].tag = combined[0].tag || 'vless-out';
        }
        applySingboxRouteFinal(singboxCurrentConfig.config, combined);
        singboxCurrentConfig.proxyOutbounds = combined;
        singboxCurrentConfig.config.outbounds = buildOutboundsArray(combined, singboxCurrentConfig.directBlock);
        if (combined.length >= 2) ensureClashApi(singboxCurrentConfig.config);
        stripUnsupportedSingboxOutboundFields(singboxCurrentConfig.config);
        singboxProxyLinks = [];
        combined.forEach(function (o) {
            const link = outboundToLink(o);
            singboxProxyLinks.push(link || '(не удалось преобразовать в ссылку)');
        });
        singboxDirty = true;
        if (msgEl) msgEl.textContent = 'Добавлено: ' + newOutbounds.length + '. Нажмите «Сохранить» для применения.';
        if (inputEl) inputEl.value = '';
        renderSingboxProxyList();
        renderUrltestOptions();
        if (typeof window.settingsUpdateSaveButton === 'function') window.settingsUpdateSaveButton();
    } catch (err) {
        if (msgEl) msgEl.textContent = 'Ошибка: ' + err.message;
        if (typeof showToast === 'function') showToast('Ошибка: ' + err.message, 3000);
        window._singboxLastDebug = true;
        if (typeof console !== 'undefined') console.error('[singbox debug] add error', err);
    } finally {
        if (btnEl) btnEl.disabled = false;
        if (typeof hideProgress === 'function') hideProgress();
    }
}

function isSingboxDirty() {
    return singboxDirty;
}

function setSingboxDirty(value) {
    singboxDirty = !!value;
}

async function saveSingboxDraft() {
    if (!singboxDirty || !singboxCurrentConfig) return { success: true };
    var configToSave = stripControlChars(singboxCurrentConfig.config);
    var configStr = stripControlCharsFromJsonString(JSON.stringify(configToSave, null, 2));
    if (typeof showProgress === 'function') showProgress('Сохранение конфигурации...');
    try {
        const data = await apiRequest(SINGBOX_CONFIG_POST, 'POST', { config: configStr });
        if (data.success) singboxDirty = false;
        return data;
    } catch (err) {
        return { success: false, error: err.message };
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
    }
}

function bindUrltestOptionsInputs() {
    ['singbox-urltest-url', 'singbox-urltest-interval', 'singbox-urltest-tolerance'].forEach(function (id) {
        var el = document.getElementById(id);
        if (el) el.addEventListener('change', function () { singboxDirty = true; if (typeof window.settingsUpdateSaveButton === 'function') window.settingsUpdateSaveButton(); });
    });
}

async function runSettingsProxyDelayTest() {
    var btn = document.getElementById('singbox-settings-proxy-delay-btn');
    var resultEl = document.getElementById('singbox-settings-proxy-delay-result');
    if (!btn || !resultEl) return;
    btn.disabled = true;
    resultEl.textContent = 'Проверка…';
    try {
        var data = await apiRequest('/singbox/proxies/delay?group=allow-proxy&timeout=5000');
        if (data && data.error) {
            resultEl.textContent = data.error || 'Ошибка';
            return;
        }
        var parts = [];
        if (data && typeof data === 'object' && !Array.isArray(data)) {
            Object.keys(data).forEach(function (tag) {
                var v = data[tag];
                var label = (tag === URLTEST_TAG) ? 'Авто' : tag;
                if (typeof v === 'number') parts.push(label + ': ' + v + ' ms');
                else if (v && v.message) parts.push(label + ': ' + v.message);
                else parts.push(label + ': —');
            });
        }
        resultEl.textContent = parts.length ? parts.join(', ') : 'Нет данных';
    } catch (e) {
        resultEl.textContent = e.message || 'Ошибка';
    } finally {
        btn.disabled = false;
    }
}

document.addEventListener('DOMContentLoaded', function () {
    loadSingboxProxyList();
    bindUrltestOptionsInputs();
    var delayBtn = document.getElementById('singbox-settings-proxy-delay-btn');
    if (delayBtn) delayBtn.addEventListener('click', runSettingsProxyDelayTest);
});

window.isSingboxDirty = isSingboxDirty;
window.setSingboxDirty = setSingboxDirty;
window.saveSingboxDraft = saveSingboxDraft;
window.SELECTOR_TAG = SELECTOR_TAG;
window.URLTEST_TAG = URLTEST_TAG;
