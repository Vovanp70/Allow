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
    var urltestPart = {
        type: 'urltest',
        tag: URLTEST_TAG,
        outbounds: proxyTags,
        url: URLTEST_URL,
        interval: URLTEST_INTERVAL,
        tolerance: URLTEST_TOLERANCE
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
        singboxCurrentConfig = { config: config, proxyOutbounds: proxyOutbounds, directBlock: directBlock };
        singboxProxyLinks = links;
        singboxDirty = false;
        renderSingboxProxyList();
    } catch (err) {
        listEl.innerHTML = '<p style="color: #c00;">Ошибка загрузки: ' + (err.message || 'сеть') + '</p>';
        singboxCurrentConfig = null;
        singboxProxyLinks = [];
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
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
                singboxCurrentConfig = { config: config, proxyOutbounds: proxyOutbounds, directBlock: directBlock };
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

document.addEventListener('DOMContentLoaded', function () {
    loadSingboxProxyList();
});

window.isSingboxDirty = isSingboxDirty;
window.setSingboxDirty = setSingboxDirty;
window.saveSingboxDraft = saveSingboxDraft;
window.SELECTOR_TAG = SELECTOR_TAG;
window.URLTEST_TAG = URLTEST_TAG;
