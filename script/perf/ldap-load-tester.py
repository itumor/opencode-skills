#!/usr/bin/env python3
"""
LDAP Performance Load Tester
Runs concurrent LDAP operations (bind, search, add, modify, delete)
using subprocess with ldapsearch/ldapadd/ldapmodify/ldapdelete.
"""
import subprocess
import time
import sys
import os
import json
import argparse
import threading
from collections import defaultdict, deque
from concurrent.futures import ThreadPoolExecutor, as_completed

class LDAPLoadTester:
    def __init__(self, host, port, base_dn, admin_dn, admin_pw, user_prefix="user",
                 user_count=100000, tls=True):
        self.host = host
        self.port = port
        self.base_dn = base_dn
        self.admin_dn = admin_dn
        self.admin_pw = admin_pw
        self.user_prefix = user_prefix
        self.user_count = user_count
        self.tls = tls
        self.stats = defaultdict(int)
        self.latencies = defaultdict(list)
        self.lock = threading.Lock()
        self.start_time = time.time()
        self.stop_event = threading.Event()

    def _ldap_cmd(self, op, **kwargs):
        """Build ldap command"""
        uri = f"ldaps://{self.host}:{self.port}" if self.tls else f"ldap://{self.host}:{self.port}"
        env = os.environ.copy()
        env['LDAPTLS_REQCERT'] = 'never'
        env['PATH'] = '/opt/symas/bin:/opt/symas/sbin:' + env.get('PATH', '/usr/bin')

        if op == 'search':
            user_id = kwargs.get('user_id', 1)
            uid = f"{self.user_prefix}{user_id:07d}"
            bind_dn = f"uid={uid},ou=Users,{self.base_dn}"
            return ['ldapsearch', '-x', '-H', uri,
                    '-D', bind_dn, '-w', kwargs.get('password', 'Test123!'),
                    '-b', self.base_dn, '-s', 'sub',
                    f'(uid={uid})', 'dn', '-o', 'ldif-wrap=no',
                    '-o', 'nettimeout=5'], env

        elif op == 'admin_search':
            return ['ldapsearch', '-x', '-H', uri,
                    '-D', self.admin_dn, '-w', self.admin_pw,
                    '-b', self.base_dn, '-s', 'sub',
                    kwargs.get('filter', '(objectClass=inetOrgPerson)'),
                    'dn', '-z', str(kwargs.get('size_limit', 10)),
                    '-o', 'ldif-wrap=no',
                    '-o', 'nettimeout=5'], env

        elif op == 'add':
            user_id = kwargs.get('user_id', 0)
            uid = f"churn{user_id:07d}"
            dn = f"uid={uid},ou=Users,{self.base_dn}"
            ldif = f"""dn: {dn}
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: top
uid: {uid}
cn: Churn User {uid}
sn: {uid}
mail: {uid}@bank.local
userPassword: Test123!
"""
            return ['ldapadd', '-x', '-H', uri,
                    '-D', self.admin_dn, '-w', self.admin_pw,
                    '-o', 'nettimeout=5'], env, ldif.encode()

        elif op == 'modify':
            user_id = kwargs.get('user_id', 1)
            uid = f"{self.user_prefix}{user_id:07d}"
            dn = f"uid={uid},ou=Users,{self.base_dn}"
            ldif = f"""dn: {dn}
changetype: modify
replace: description
description: Modified at {int(time.time())}
"""
            return ['ldapmodify', '-x', '-H', uri,
                    '-D', self.admin_dn, '-w', self.admin_pw,
                    '-o', 'nettimeout=5'], env, ldif.encode()

        elif op == 'delete':
            user_id = kwargs.get('user_id', 0)
            uid = f"churn{user_id:07d}"
            dn = f"uid={uid},ou=Users,{self.base_dn}"
            return ['ldapdelete', '-x', '-H', uri,
                    '-D', self.admin_dn, '-w', self.admin_pw,
                    '-o', 'nettimeout=5', dn], env

        return [], env

    def _run_op(self, op, **kwargs):
        """Execute a single LDAP operation"""
        result = self._ldap_cmd(op, **kwargs)
        if len(result) == 2:
            cmd, env = result
            stdin_data = None
        else:
            cmd, env, stdin_data = result

        start = time.time()
        try:
            proc = subprocess.run(cmd, env=env, input=stdin_data,
                                  capture_output=True, timeout=10)
            elapsed = (time.time() - start) * 1000
            # ldapsearch returns 0=success, 32=no matches (still success), others=fail
            rc = proc.returncode
            success = rc in (0, 32) if op == 'search' else (rc == 0)

            with self.lock:
                self.stats[f'{op}_total'] += 1
                if success:
                    self.stats[f'{op}_success'] += 1
                else:
                    self.stats[f'{op}_fail'] += 1
                self.latencies[op].append(elapsed)
            return success, elapsed
        except (subprocess.TimeoutExpired, Exception) as e:
            elapsed = (time.time() - start) * 1000
            with self.lock:
                self.stats[f'{op}_total'] += 1
                self.stats[f'{op}_timeout'] += 1
                self.latencies[op].append(elapsed)
            return False, elapsed

    def run_login_load(self, target_ops_per_sec, duration_sec, concurrency=50):
        """Simulate login load: bind as user + search"""
        interval = 1.0 / target_ops_per_sec if target_ops_per_sec > 0 else 0
        print(f"  Login load: {target_ops_per_sec} ops/sec, {concurrency} threads, {duration_sec}s")

        def worker():
            while not self.stop_event.is_set():
                user_id = (hash(threading.get_ident()) + int(time.time() * 1000)) % self.user_count + 1
                self._run_op('search', user_id=user_id, password='Test123!')
                if interval > 0:
                    time.sleep(interval * concurrency)

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(worker) for _ in range(concurrency)]
            time.sleep(duration_sec)
            self.stop_event.set()
            for f in futures:
                f.cancel()

    def run_write_load(self, target_ops_per_sec, duration_sec, op='add', concurrency=10):
        """Simulate write operations (add/modify/delete)"""
        interval = 1.0 / target_ops_per_sec if target_ops_per_sec > 0 else 0
        print(f"  Write load ({op}): {target_ops_per_sec} ops/sec, {duration_sec}s")

        stop_flag = threading.Event()

        def worker():
            counter = [int(time.time() * 1000)]
            while not stop_flag.is_set():
                user_id = (counter[0] + hash(threading.get_ident())) % 100000 + 1
                counter[0] += 1
                self._run_op(op, user_id=user_id)
                if interval > 0:
                    time.sleep(interval * concurrency)

        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [executor.submit(worker) for _ in range(concurrency)]
            time.sleep(duration_sec)
            stop_flag.set()
            for f in futures:
                f.cancel()

    def run_stress_ramp(self, duration_total=3600, ramp_interval=300):
        """Gradually increase load from 50 to 2000 ops/sec"""
        ramp_steps = [50, 100, 250, 500, 750, 1000, 1500, 2000]
        step_duration = min(duration_total // len(ramp_steps), ramp_interval)
        print(f"  Stress ramp: {ramp_steps} steps, {step_duration}s each")

        for ops in ramp_steps:
            if self.stop_event.is_set():
                break
            print(f"    Ramping to {ops} ops/sec...")
            self.stop_event.clear()
            concurrency = min(ops // 2, 100)
            self.run_login_load(ops, step_duration, concurrency=concurrency)

    def get_report(self):
        """Generate a test report"""
        elapsed = time.time() - self.start_time
        report = {
            'elapsed_sec': round(elapsed, 1),
            'total_ops': sum(self.stats.get(f'{op}_total', 0) for op in ['search', 'add', 'modify', 'delete']),
            'ops_per_sec': 0,
            'errors': self.stats.get('search_fail', 0) + self.stats.get('add_fail', 0) +
                       self.stats.get('modify_fail', 0) + self.stats.get('delete_fail', 0),
            'error_rate': 0,
            'latency_p50': {},
            'latency_p95': {},
            'latency_p99': {},
        }

        total = report['total_ops']
        report['ops_per_sec'] = round(total / elapsed, 1) if elapsed > 0 else 0
        report['error_rate'] = round(report['errors'] / max(total, 1) * 100, 2)

        for op in ['search', 'add', 'modify', 'delete']:
            lats = sorted(self.latencies.get(op, []))
            if lats:
                report['latency_p50'][op] = round(lats[len(lats)//2], 1)
                report['latency_p95'][op] = round(lats[int(len(lats)*0.95)], 1)
                report['latency_p99'][op] = round(lats[int(len(lats)*0.99)], 1)
            else:
                report['latency_p50'][op] = 0
                report['latency_p95'][op] = 0
                report['latency_p99'][op] = 0

        return report


def main():
    parser = argparse.ArgumentParser(description='LDAP Load Tester')
    parser.add_argument('--host', default='10.40.1.10', help='LDAP server host')
    parser.add_argument('--port', type=int, default=636, help='LDAP port')
    parser.add_argument('--base-dn', default='dc=eab,dc=bank,dc=local')
    parser.add_argument('--admin-dn', default='cn=admin,dc=eab,dc=bank,dc=local')
    parser.add_argument('--admin-pw', default='TheN1le1')
    parser.add_argument('--user-count', type=int, default=100000)
    parser.add_argument('--mode', choices=['login', 'write', 'mixed', 'stress'],
                        default='login', help='Test mode')
    parser.add_argument('--target-ops', type=int, default=100,
                        help='Target ops per second')
    parser.add_argument('--duration', type=int, default=60,
                        help='Test duration in seconds')
    parser.add_argument('--concurrency', type=int, default=50,
                        help='Number of concurrent threads')
    parser.add_argument('--json', action='store_true', help='Output JSON report')
    args = parser.parse_args()

    tester = LDAPLoadTester(
        host=args.host, port=args.port, base_dn=args.base_dn,
        admin_dn=args.admin_dn, admin_pw=args.admin_pw,
        user_count=args.user_count, tls=(args.port == 636)
    )

    print(f"=== LDAP Load Test ===")
    print(f"  Host: {args.host}:{args.port}")
    print(f"  Mode: {args.mode}")
    print(f"  Target: {args.target_ops} ops/sec")
    print(f"  Duration: {args.duration}s")
    print(f"  Users: {args.user_count}")
    print()

    start = time.time()

    if args.mode == 'login':
        tester.run_login_load(args.target_ops, args.duration, concurrency=args.concurrency)
        # Brief cool-down
        time.sleep(2)
    elif args.mode == 'write':
        tester.run_write_load(args.target_ops, args.duration, op='add', concurrency=args.concurrency)
        time.sleep(2)
    elif args.mode == 'mixed':
        t1 = threading.Thread(target=tester.run_login_load,
                              args=(int(args.target_ops * 0.8), args.duration, args.concurrency))
        t2 = threading.Thread(target=tester.run_write_load,
                              args=(int(args.target_ops * 0.2), args.duration, 'modify', max(args.concurrency // 5, 1)))
        t1.start(); t2.start()
        t1.join(); t2.join()
        time.sleep(2)
    elif args.mode == 'stress':
        tester.run_stress_ramp(args.duration)
        time.sleep(2)

    report = tester.get_report()
    report['actual_duration'] = round(time.time() - start, 1)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{'='*60}")
        print(f"TEST REPORT")
        print(f"{'='*60}")
        print(f"  Duration:      {report['elapsed_sec']}s")
        print(f"  Total ops:     {report['total_ops']}")
        print(f"  Ops/sec:       {report['ops_per_sec']}")
        print(f"  Errors:        {report['errors']}")
        print(f"  Error rate:    {report['error_rate']}%")
        print(f"  Latency (search):")
        print(f"    p50: {report['latency_p50'].get('search', 0)}ms")
        print(f"    p95: {report['latency_p95'].get('search', 0)}ms")
        print(f"    p99: {report['latency_p99'].get('search', 0)}ms")
        print(f"  Latency (modify):")
        print(f"    p50: {report['latency_p50'].get('modify', 0)}ms")
        print(f"    p95: {report['latency_p95'].get('modify', 0)}ms")
        print(f"    p99: {report['latency_p99'].get('modify', 0)}ms")
        print(f"{'='*60}")


if __name__ == '__main__':
    main()
