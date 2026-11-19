"""Read-only wire checks against a running connector; never sends a PDF."""
import http.client
import json
import sys


def request(method, route, headers):
    conn = http.client.HTTPConnection('127.0.0.1', 43127, timeout=10)
    try:
        conn.request(method, route, headers=headers)
        r = conn.getresponse()
        return r.status, r.headers, r.read()
    finally:
        conn.close()


def check(origin):
    headers = {'Origin': origin, 'X-Pdf-Tools': 'versaworks'}
    code, h, body = request('GET', '/status', headers)
    assert code == 200 and h['Access-Control-Allow-Origin'] == origin
    assert type(json.loads(body)['available']) is bool
    for modified in ({'Host': 'localhost:43127'}, {'Origin': 'null'}, {'X-Pdf-Tools': 'other'}):
        assert request('GET', '/status', {**headers, **modified})[0] == 403
    assert request('GET', '/status', {'Origin': origin})[0] == 403
    assert request('GET', '/jobs', headers)[0] == 405
    assert request('POST', '/jobs', headers)[0] == 415
    assert request('POST', '/jobs', {**headers, 'Content-Type': 'application/pdf'})[0] == 422
    for path, method, fields in [('/status', 'GET', 'x-pdf-tools'),
                                 ('/jobs', 'POST', 'content-type, x-pdf-tools')]:
        pre = {'Origin': origin, 'Access-Control-Request-Method': method,
               'Access-Control-Request-Headers': fields,
               'Access-Control-Request-Private-Network': 'true'}
        code, h, _ = request('OPTIONS', path, pre)
        assert code == 204 and h['Access-Control-Allow-Private-Network'] == 'true'
        assert h['Access-Control-Allow-Origin'] == origin and h['Access-Control-Allow-Methods'] == method
        assert h['Access-Control-Allow-Headers'] == fields
        pre['Access-Control-Request-Headers'] += ', unexpected'
        assert request('OPTIONS', path, pre)[0] == 403
    print('Connector smoke checks passed (no job published).')


if __name__ == '__main__':
    check(sys.argv[1])
