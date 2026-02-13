(function() {
    function closeMenu() {
        document.body.classList.remove('mobile-menu-open');
        var btn = document.querySelector('.mobile-menu-toggle');
        if (btn) btn.setAttribute('aria-expanded', 'false');
    }

    function openMenu() {
        document.body.classList.add('mobile-menu-open');
        var btn = document.querySelector('.mobile-menu-toggle');
        if (btn) btn.setAttribute('aria-expanded', 'true');
    }

    function toggleMenu() {
        if (document.body.classList.contains('mobile-menu-open')) {
            closeMenu();
        } else {
            openMenu();
        }
    }

    document.addEventListener('DOMContentLoaded', function() {
        var toggle = document.querySelector('.mobile-menu-toggle');
        var drawer = document.querySelector('.sidebar-drawer');
        if (!toggle || !drawer) return;

        toggle.addEventListener('click', function() {
            toggleMenu();
        });

        drawer.addEventListener('click', function(e) {
            if (e.target === drawer) closeMenu();
        });

        var menuLinks = drawer.querySelectorAll('a.menu-item');
        for (var i = 0; i < menuLinks.length; i++) {
            menuLinks[i].addEventListener('click', closeMenu);
        }

        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && document.body.classList.contains('mobile-menu-open')) {
                closeMenu();
            }
        });
    });
})();
