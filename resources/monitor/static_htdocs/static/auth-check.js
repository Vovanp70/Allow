/**
 * Auth check: on pages that include this script, verify session via GET /api/auth/check.
 * If 401, redirect to login with ?next= current path so user returns after login.
 */
(function() {
    fetch('/api/auth/check', { method: 'GET', credentials: 'same-origin' })
        .then(function(res) {
            if (res.status === 401) {
                var next = encodeURIComponent(location.pathname + location.search);
                location.href = '/login.html?next=' + next;
            }
        })
        .catch(function() {
            location.href = '/login.html';
        });
})();
