#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build static HTML from Jinja2 templates for CGI/lighttpd monitor.
Run from repo root or from resources/monitor. Output: resources/monitor/static_htdocs/
"""

import os
import shutil
import sys

# Resolve paths: script may be in resources/monitor/ or resources/monitor/etc/monitor/
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if os.path.basename(SCRIPT_DIR) == 'monitor' and os.path.isdir(os.path.join(SCRIPT_DIR, 'etc')):
    # script is resources/monitor/build_static_htdocs.py
    MONITOR_ETC = os.path.join(SCRIPT_DIR, 'etc', 'monitor')
else:
    MONITOR_ETC = SCRIPT_DIR

TEMPLATES_DIR = os.path.join(MONITOR_ETC, 'templates')
STATIC_SRC = os.path.join(MONITOR_ETC, 'static')
OUTPUT_DIR = os.path.join(SCRIPT_DIR, 'static_htdocs')

# Page template name -> (output filename, request.endpoint for sidebar active)
PAGES = [
    ('dashboard.html', 'dashboard.html', 'dashboard'),
    ('dnsmasq.html', 'dnsmasq.html', 'dnsmasq_page'),
    ('dnsmasq-family.html', 'dnsmasq-family.html', 'dnsmasq_family_page'),
    ('stubby.html', 'stubby.html', 'stubby_page'),
    ('stubby-family.html', 'stubby-family.html', 'stubby_family_page'),
    ('sing-box.html', 'sing-box.html', 'sing_box_page'),
    ('routing.html', 'routing.html', 'routing_page'),
    ('settings.html', 'settings.html', 'settings_page'),
    ('change-password.html', 'change-password.html', 'change_password_page'),
]


def url_for(endpoint, **kwargs):
    """Flask-like url_for for static build: page endpoints -> .html, static -> /static/filename."""
    if endpoint == 'static':
        filename = kwargs.get('filename', '')
        return '/static/' + filename
    m = {
        'dashboard': '/dashboard.html',
        'settings_page': '/settings.html',
        'routing_page': '/routing.html',
        'dnsmasq_page': '/dnsmasq.html',
        'dnsmasq_family_page': '/dnsmasq-family.html',
        'stubby_page': '/stubby.html',
        'stubby_family_page': '/stubby-family.html',
        'sing_box_page': '/sing-box.html',
        'change_password_page': '/change-password.html',
        'login_page': '/login.html',
    }
    return m.get(endpoint, '/')


def main():
    try:
        from jinja2 import Environment, FileSystemLoader, select_autoescape
    except ImportError:
        print('Need jinja2: pip install jinja2', file=sys.stderr)
        sys.exit(1)

    env = Environment(
        loader=FileSystemLoader(TEMPLATES_DIR),
        autoescape=select_autoescape(['html', 'xml']),
    )

    # Mock request object (endpoint set per page)
    class Request:
        endpoint = None

    request = Request()

    def globals_for_page(endpoint):
        request.endpoint = endpoint
        return {
            'url_for': url_for,
            'request': request,
        }

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUTPUT_DIR, 'static'), exist_ok=True)

    for template_name, output_name, endpoint in PAGES:
        template = env.get_template(template_name)
        html = template.render(**globals_for_page(endpoint))
        out_path = os.path.join(OUTPUT_DIR, output_name)
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(html)
        print('Rendered', output_name)

    # login.html (standalone, no sidebar)
    login_tpl = env.get_template('login.html')
    with open(os.path.join(OUTPUT_DIR, 'login.html'), 'w', encoding='utf-8') as f:
        f.write(login_tpl.render())
    print('Rendered login.html')

    # index.html -> redirect to login
    index_html = '''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=/login.html">
<title>Redirect</title>
</head>
<body>
<p><a href="/login.html">Перейти на страницу входа</a></p>
</body>
</html>
'''
    with open(os.path.join(OUTPUT_DIR, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(index_html)
    print('Rendered index.html')

    # logout.html -> POST logout then redirect to login
    logout_html = '''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Выход</title>
</head>
<body>
<p>Выход из системы…</p>
<script>
fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' })
  .then(function() { location.href = '/login.html'; })
  .catch(function() { location.href = '/login.html'; });
</script>
</body>
</html>
'''
    with open(os.path.join(OUTPUT_DIR, 'logout.html'), 'w', encoding='utf-8') as f:
        f.write(logout_html)
    print('Rendered logout.html')

    # Copy static assets
    for name in os.listdir(STATIC_SRC):
        src = os.path.join(STATIC_SRC, name)
        dst = os.path.join(OUTPUT_DIR, 'static', name)
        if os.path.isfile(src):
            shutil.copy2(src, dst)
            print('Copied static/', name)
        elif os.path.isdir(src):
            if os.path.exists(dst):
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            print('Copied static/', name, '/')

    print('Done. Output:', OUTPUT_DIR)


if __name__ == '__main__':
    main()
