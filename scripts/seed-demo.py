#!/usr/bin/env python3
"""Seed the demo flow root with realistic, generic data for screen recordings.

Idempotent: wipes and re-inserts. Targets demo-flow-root/flow.db (gitignored).
Run:  python3 scripts/seed-demo.py
"""
import os
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "demo-flow-root")
DB = os.path.join(ROOT, "flow.db")
WORK = os.path.join(ROOT, "work")  # placeholder work_dir (not used by the menubar)

TZ = timezone(timedelta(hours=5, minutes=30))
now = datetime.now(TZ)


def ago(days):
    return (now - timedelta(days=days)).isoformat(timespec="seconds")


def due(days):  # +ve future, -ve past
    return (now + timedelta(days=days)).date().isoformat()


def sid():
    return str(uuid.uuid4())


con = sqlite3.connect(DB)
c = con.cursor()

# Clean slate (children first).
for t in ("task_tags", "tasks", "playbooks", "owners", "projects"):
    c.execute(f"DELETE FROM {t}")

# Projects: (slug, name, priority, status)
projects = [
    ("payments", "Payments Platform", "high", "active"),
    ("mobile", "Mobile App", "medium", "active"),
    ("infra", "Infrastructure", "medium", "active"),
    ("growth", "Growth Experiments", "low", "active"),
]
for slug, name, prio, status in projects:
    c.execute(
        "INSERT INTO projects(slug,name,status,priority,work_dir,created_at,updated_at) "
        "VALUES(?,?,?,?,?,?,?)",
        (slug, name, status, prio, f"{WORK}/{slug}", ago(60), ago(2)),
    )

# Playbooks: (slug, name, project)
playbooks = [
    ("release-notes", "Generate release notes", "payments"),
    ("daily-standup", "Daily standup digest", "infra"),
    ("oncall-triage", "On-call triage", "infra"),
]
for slug, name, proj in playbooks:
    c.execute(
        "INSERT INTO playbooks(slug,name,project_slug,work_dir,created_at,updated_at) "
        "VALUES(?,?,?,?,?,?)",
        (slug, name, proj, f"{WORK}/{slug}", ago(45), ago(5)),
    )

# Owners: (slug, name, project, every, next_in_h, last_ago_h)
owners = [
    ("deps-guardian", "Dependency Guardian", "infra", "6h", 2, 4),
    ("pr-shepherd", "PR Shepherd", "payments", "3h", 1, 2),
]
for slug, name, proj, every, nxt, last in owners:
    c.execute(
        "INSERT INTO owners(slug,name,work_dir,project_slug,status,every,"
        "next_wake_at,last_tick_at,last_tick_status,created_at,updated_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (slug, name, f"{WORK}/owners/{slug}", proj, "active", every,
         (now + timedelta(hours=nxt)).isoformat(timespec="seconds"),
         (now - timedelta(hours=last)).isoformat(timespec="seconds"),
         "ok", ago(20), ago(0)),
    )


def add_task(slug, name, project, status, prio, tags, due_days=None,
             waiting=None, updated_days=1, assignee=None, kind="regular",
             playbook=None):
    needs_session = status != "backlog"
    c.execute(
        "INSERT INTO tasks(slug,name,project_slug,status,kind,playbook_slug,priority,"
        "work_dir,waiting_on,due_date,assignee,status_changed_at,session_id,"
        "session_started,created_at,updated_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (slug, name, project, status, kind, playbook, prio,
         f"{WORK}/{project or 'floating'}", waiting,
         due(due_days) if due_days is not None else None, assignee,
         ago(updated_days), sid() if needs_session else None,
         ago(updated_days) if needs_session else None,
         ago(updated_days + 5), ago(updated_days)),
    )
    for tag in tags:
        c.execute("INSERT INTO task_tags(task_slug,tag,created_at) VALUES(?,?,?)",
                  (slug, tag, ago(updated_days)))


# Regular tasks — mix of status / priority / tags / due / waiting / stale.
add_task("apple-pay", "Add Apple Pay support", "payments", "in-progress", "high",
         ["ios", "payments"], due_days=2, updated_days=1)
add_task("pci-remediation", "PCI audit remediation", "payments", "in-progress", "high",
         ["security"], due_days=-5, updated_days=18)   # overdue + stale
add_task("refund-retries", "Refund webhook retries", "payments", "backlog", "medium",
         ["backend"], updated_days=3)
add_task("stripe-v2", "Migrate to Stripe v2 API", "payments", "done", "high",
         ["backend"], updated_days=6)

add_task("dark-mode", "Dark mode", "mobile", "in-progress", "medium",
         ["ios", "ui"], updated_days=2)
add_task("cold-start-crash", "Fix crash on cold start", "mobile", "in-progress", "high",
         ["bug"], waiting="QA to reproduce on iOS 18", updated_days=9)
add_task("onboarding-redesign", "Onboarding redesign", "mobile", "backlog", "medium",
         ["ux"], updated_days=12)
add_task("appstore-shots", "App Store screenshots", "mobile", "done", "low",
         ["marketing"], updated_days=20)

add_task("log-cost", "Cut log storage cost", "infra", "in-progress", "medium",
         ["cost"], updated_days=1)
add_task("node-autoscaling", "K8s node autoscaling", "infra", "backlog", "high",
         ["k8s"], updated_days=5)
add_task("pg-failover", "Postgres failover drill", "infra", "done", "medium",
         ["reliability"], updated_days=25)

add_task("referral-ab", "Referral program A/B test", "growth", "in-progress", "low",
         ["experiment"], updated_days=4)
add_task("seo-pages", "SEO landing pages", "growth", "backlog", "low",
         ["marketing"], updated_days=30)   # stale

# Floating tasks.
add_task("tls-renew", "Renew TLS certificates", None, "in-progress", "high",
         ["ops"], due_days=1, updated_days=1)

# Owner question (parked for a human): tagged question + owner:<slug>.
add_task("triage-meetings", "Decide: roll back deps bump?", None, "backlog", "high",
         ["question", "owner:deps-guardian"], assignee="you", updated_days=0)

# Playbook runs (kind=playbook_run).
add_task("release-notes--run-1", "release-notes run", "payments", "in-progress", "medium",
         [], updated_days=0, kind="playbook_run", playbook="release-notes")
add_task("daily-standup--run-1", "daily-standup run", "infra", "done", "medium",
         [], updated_days=1, kind="playbook_run", playbook="daily-standup")
add_task("daily-standup--run-2", "daily-standup run", "infra", "done", "medium",
         [], updated_days=2, kind="playbook_run", playbook="daily-standup")
add_task("oncall-triage--run-1", "oncall-triage run", "infra", "in-progress", "high",
         [], updated_days=0, kind="playbook_run", playbook="oncall-triage")

con.commit()

# Summary
for label, q in [
    ("projects", "SELECT COUNT(*) FROM projects"),
    ("regular tasks", "SELECT COUNT(*) FROM tasks WHERE kind='regular'"),
    ("  in-progress", "SELECT COUNT(*) FROM tasks WHERE kind='regular' AND status='in-progress'"),
    ("  backlog", "SELECT COUNT(*) FROM tasks WHERE kind='regular' AND status='backlog'"),
    ("  done", "SELECT COUNT(*) FROM tasks WHERE kind='regular' AND status='done'"),
    ("playbooks", "SELECT COUNT(*) FROM playbooks"),
    ("playbook runs", "SELECT COUNT(*) FROM tasks WHERE kind='playbook_run'"),
    ("owners", "SELECT COUNT(*) FROM owners"),
    ("question tasks", "SELECT COUNT(DISTINCT task_slug) FROM task_tags WHERE tag='question'"),
    ("tags", "SELECT COUNT(DISTINCT tag) FROM task_tags"),
]:
    c.execute(q)
    print(f"{label:>16}: {c.fetchone()[0]}")

con.close()
print("\nseeded:", DB)
