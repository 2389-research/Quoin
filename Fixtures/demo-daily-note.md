---
title: Q3 Planning — Kickoff
date: 2026-07-14
tags: [meeting, q3, planning, roadmap]
pinned: true
project: Atlas
status: active
aliases:
  - Q3 Kickoff
  - Atlas Planning
---

# Q3 Planning — Kickoff

Rough morning — the espresso machine died again — but a genuinely good
kickoff. We finally have alignment on what Atlas ships before the September
freeze. Writing this up while it's fresh, mostly for future-me and anyone
who missed the room.

Big takeaway: we're cutting the offline-sync epic from Q3 and moving it to
Q4. Nobody loved saying it out loud, but the numbers made the call for us.

## Meeting notes

Held in the Blue Room, 10:00–11:15. Priya ran it; I took notes.

- Reviewed last quarter's carryover — three items, all closable.
- Walked the Atlas roadmap top to bottom; trimmed it to two headline bets.
- ==Decided to defer offline-sync to Q4== so the team can land the search
  rewrite without splitting focus.
- Agreed the beta cohort stays capped at 50 accounts through August.

### Action items

- [x] Priya to circulate the trimmed roadmap deck
- [x] Confirm the search rewrite has design sign-off
- [ ] Marcus to spike the new indexing service by 7/21
- [ ] Me: write the offline-sync deferral note for the changelog[^defer]
- [ ] Dana to schedule the beta-cohort check-in with support
- [ ] Book the mid-quarter review room before it's gone again

## Attendees

| Name          | Role              | Present |
|---------------|-------------------|:-------:|
| Priya Anand   | PM (Atlas)        | Yes     |
| Marcus Lee    | Eng lead          | Yes     |
| Dana Whitfield| Design            | Yes     |
| Sam Okafor    | Support           | Remote  |
| Jules Renner  | Data              | No[^jules] |

## Decision log

| # | Decision                            | Owner   | Status   |
|---|-------------------------------------|---------|----------|
| 1 | Defer offline-sync to Q4            | Priya   | Final    |
| 2 | Prioritize search rewrite for Q3    | Marcus  | Final    |
| 3 | Keep beta cohort capped at 50       | Dana    | Trial    |
| 4 | Revisit pricing tiers next quarter  | —       | Parked   |

> The best thing we did today was say "no" to something good so we could
> say "yes" to something better.
>
> — Priya, closing the room

## Links & references

- Roadmap deck: [Atlas Q3 (Figma)](https://example.com/atlas-q3-deck)
- Metrics that drove the sync call: [dashboard](https://example.com/metrics/sync)
- Related note: [[Search Rewrite — Design Notes]]
- The framing on "good vs. better" came from [Essentialism](https://example.com/essentialism),
  which I finally started this week.

## Notes to self

Marcus made a quiet but important point: the indexing spike should measure
cold-start latency, not just steady-state throughput — that's where the last
rewrite fooled us.[^cold] Flag it in the spike template.

Also: stop scheduling planning at 10am. Everyone's still on their first
coffee and the first fifteen minutes are dead air.

[^defer]: The deferral note should be one paragraph, link the metrics
dashboard, and land in the public changelog before the 7/18 release cut.
[^jules]: Jules was out but sent async data comments — folded into decision #1.
[^cold]: Last quarter's rewrite looked 30% faster in benchmarks and slower in
production because cold-start dominated real traffic.
