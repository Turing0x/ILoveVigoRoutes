#!/usr/bin/env python3
"""Builds the real-street transfer table the planner ships in its bundle.

Why this exists
---------------
`WalkModel` turns straight-line distance into walking time by multiplying it by a
detour factor. Measured against a real pedestrian graph over fourteen Vigo stop
pairs, that factor's per-pair error runs from -28% to +29%
(`AUDITORIA-MOTOR-VS-CONCELLO.md` F-2). A transfer underestimated by 28% is a
connection the passenger cannot actually make; one overestimated by 29% is a
connection that silently drops out of the footpath graph.

Both disappear if the distance is simply correct. Stop-to-stop transfers are the
half of the problem that can be solved once, offline, because both ends are known
in advance: there are only a few thousand pairs close enough to matter. This
script routes every one of them over OpenStreetMap's pedestrian network and emits
a table the app reads instead of guessing.

The other half — origin to first stop, last stop to destination — cannot be
precomputed, because those ends are wherever the user happens to be. That is B3.

Usage
-----
    python3 Tools/build_footpaths.py \
        --stops   path/to/stops.txt \
        --osm     path/to/vigo_walk.json \
        --out     VigoCore/Sources/VigoCore/Resources/footpaths.csv

Getting the OSM extract (one Overpass query, a few minutes):

    curl -o vigo_walk.json --data-urlencode "data@Tools/overpass_walk.ql" \
         https://overpass-api.de/api/interpreter

Data is © OpenStreetMap contributors, ODbL.
"""

import argparse
import csv
import heapq
import json
import math
import sys
import time
from collections import defaultdict

EARTH_RADIUS_M = 6_371_000.0


def haversine(lat_a, lon_a, lat_b, lon_b):
    rad = math.radians
    d_lat = rad(lat_b - lat_a)
    d_lon = rad(lon_b - lon_a)
    h = (math.sin(d_lat / 2) ** 2
         + math.cos(rad(lat_a)) * math.cos(rad(lat_b)) * math.sin(d_lon / 2) ** 2)
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


class Grid:
    """Coarse spatial index. Plain dict of cells; good enough at this scale."""

    def __init__(self, cell_metres):
        self.cell = cell_metres
        self.lat_span = cell_metres / 111_320.0
        self.buckets = defaultdict(list)

    def _key(self, lat, lon):
        lon_span = self.cell / (111_320.0 * max(0.1, math.cos(math.radians(lat))))
        return (int(lat / self.lat_span), int(lon / lon_span))

    def add(self, lat, lon, payload):
        self.buckets[self._key(lat, lon)].append((lat, lon, payload))

    def near(self, lat, lon, rings=1):
        r0, c0 = self._key(lat, lon)
        for dr in range(-rings, rings + 1):
            for dc in range(-rings, rings + 1):
                yield from self.buckets.get((r0 + dr, c0 + dc), ())


def load_osm_graph(path):
    """Node coordinates and an adjacency list, from an Overpass `out skel` dump."""
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)

    coords = {}
    ways = []
    for element in raw["elements"]:
        if element["type"] == "node":
            coords[element["id"]] = (element["lat"], element["lon"])
        elif element["type"] == "way":
            ways.append(element["nodes"])

    adjacency = defaultdict(list)
    edges = 0
    for node_ids in ways:
        for a, b in zip(node_ids, node_ids[1:]):
            pa, pb = coords.get(a), coords.get(b)
            if pa is None or pb is None:
                continue
            length = haversine(pa[0], pa[1], pb[0], pb[1])
            if length <= 0:
                continue
            # Undirected: pedestrians ignore one-ways, which is the whole point of
            # routing on the walking network rather than the driving one.
            adjacency[a].append((b, length))
            adjacency[b].append((a, length))
            edges += 1
    return coords, adjacency, edges


def largest_component(adjacency):
    """The main walkable network, so a stop cannot snap onto an orphan fragment.

    An isolated courtyard path 20 m from a stop would otherwise capture it and
    leave that stop with no transfers at all — a silent hole, and exactly the kind
    of failure that is invisible until someone is standing at the wrong pole.
    """
    seen = set()
    best = set()
    for start in adjacency:
        if start in seen:
            continue
        stack = [start]
        seen.add(start)
        component = {start}
        while stack:
            node = stack.pop()
            for neighbour, _ in adjacency[node]:
                if neighbour not in seen:
                    seen.add(neighbour)
                    component.add(neighbour)
                    stack.append(neighbour)
        if len(component) > len(best):
            best = component
    return best


def snap_stops(stops, coords, component, max_snap_metres):
    """Nearest graph node to each stop, plus the straight-line residual to it.

    Snapping to a node rather than to the nearest point on an edge costs a few
    metres on a dense urban network and saves splitting every way. The residual is
    added back at both ends of every route, so it is accounted for rather than
    ignored.
    """
    grid = Grid(200)
    for node_id in component:
        lat, lon = coords[node_id]
        grid.add(lat, lon, node_id)

    snapped = {}
    unsnapped = []
    for stop in stops:
        lat, lon = stop["lat"], stop["lon"]
        best_node, best_distance = None, float("inf")
        rings = 1
        while rings <= 6:
            for cand_lat, cand_lon, node_id in grid.near(lat, lon, rings):
                distance = haversine(lat, lon, cand_lat, cand_lon)
                if distance < best_distance:
                    best_node, best_distance = node_id, distance
            if best_node is not None and best_distance <= rings * 200:
                break
            rings += 1
        if best_node is None or best_distance > max_snap_metres:
            unsnapped.append((stop["id"], round(best_distance, 1) if best_node else None))
            continue
        snapped[stop["id"]] = (best_node, best_distance)
    return snapped, unsnapped


def route_from(source_node, adjacency, cutoff, targets_by_node):
    """Dijkstra from one node, abandoned past `cutoff` metres.

    The cutoff is what keeps this cheap: each search touches a neighbourhood, not
    the city, so the whole run is a few thousand small searches rather than one
    all-pairs problem.
    """
    distances = {source_node: 0.0}
    found = {}
    queue = [(0.0, source_node)]
    while queue:
        distance, node = heapq.heappop(queue)
        if distance > distances.get(node, float("inf")):
            continue
        if distance > cutoff:
            break
        if node in targets_by_node:
            for stop_id in targets_by_node[node]:
                if stop_id not in found:
                    found[stop_id] = distance
        for neighbour, length in adjacency[node]:
            candidate = distance + length
            if candidate < distances.get(neighbour, float("inf")) and candidate <= cutoff:
                distances[neighbour] = candidate
                heapq.heappush(queue, (candidate, neighbour))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stops", required=True, help="GTFS stops.txt")
    parser.add_argument("--osm", required=True, help="Overpass JSON of the walkable network")
    parser.add_argument("--out", required=True, help="CSV to write")
    parser.add_argument("--max-metres", type=float, default=400.0,
                        help="longest transfer kept, in real walked metres (default 400)")
    parser.add_argument("--candidate-metres", type=float, default=600.0,
                        help="straight-line radius searched for candidate pairs (default 600)")
    parser.add_argument("--max-snap-metres", type=float, default=120.0,
                        help="a stop further than this from any path is left out (default 120)")
    args = parser.parse_args()

    started = time.time()

    with open(args.stops, encoding="utf-8-sig") as handle:
        stops = [{"id": r["stop_id"], "lat": float(r["stop_lat"]), "lon": float(r["stop_lon"])}
                 for r in csv.DictReader(handle)]
    print(f"stops                 {len(stops)}", file=sys.stderr)

    coords, adjacency, edge_count = load_osm_graph(args.osm)
    print(f"osm nodes/edges       {len(coords)} / {edge_count}", file=sys.stderr)

    component = largest_component(adjacency)
    print(f"largest component     {len(component)} nodes "
          f"({100 * len(component) / max(1, len(adjacency)):.1f}% of routable)", file=sys.stderr)

    snapped, unsnapped = snap_stops(stops, coords, component, args.max_snap_metres)
    print(f"stops snapped         {len(snapped)}  (unsnapped {len(unsnapped)})", file=sys.stderr)
    if unsnapped:
        preview = ", ".join(f"{sid}@{d}m" for sid, d in unsnapped[:8])
        print(f"  unsnapped sample    {preview}", file=sys.stderr)

    targets_by_node = defaultdict(list)
    for stop_id, (node_id, _) in snapped.items():
        targets_by_node[node_id].append(stop_id)

    by_id = {s["id"]: s for s in stops}
    order = sorted(snapped, key=lambda sid: by_id[sid]["lat"])
    lat_span = args.candidate_metres / 111_320.0
    candidates = defaultdict(set)
    for index, stop_id in enumerate(order):
        a = by_id[stop_id]
        for other_id in order[index + 1:]:
            b = by_id[other_id]
            if b["lat"] - a["lat"] > lat_span:
                break
            if haversine(a["lat"], a["lon"], b["lat"], b["lon"]) <= args.candidate_metres:
                candidates[stop_id].add(other_id)
                candidates[other_id].add(stop_id)
    total_candidates = sum(len(v) for v in candidates.values()) // 2
    print(f"candidate pairs       {total_candidates}", file=sys.stderr)

    # Route from every stop; keep the shorter of the two directions. They should be
    # identical on an undirected graph, but snapping residuals differ per end, so
    # taking the minimum keeps the table symmetric by construction rather than by
    # assumption.
    pair_metres = {}
    for done, (stop_id, (node_id, residual)) in enumerate(snapped.items(), 1):
        wanted = candidates.get(stop_id)
        if not wanted:
            continue
        cutoff = args.max_metres + args.candidate_metres
        reached = route_from(node_id, adjacency, cutoff, targets_by_node)
        for other_id, network_metres in reached.items():
            if other_id == stop_id or other_id not in wanted:
                continue
            other_residual = snapped[other_id][1]
            total = network_metres + residual + other_residual
            if total > args.max_metres:
                continue
            key = (stop_id, other_id) if stop_id < other_id else (other_id, stop_id)
            if total < pair_metres.get(key, float("inf")):
                pair_metres[key] = total
        if done % 200 == 0:
            print(f"  routed {done}/{len(snapped)}", file=sys.stderr)

    rows = sorted((a, b, int(round(m))) for (a, b), m in pair_metres.items())
    with open(args.out, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(["from_stop_id", "to_stop_id", "metres"])
        writer.writerows(rows)

    # What the straight-line model would have said for the same pairs, so the gain
    # is a number in the log rather than a claim.
    ratios = []
    for (a, b), metres in pair_metres.items():
        sa, sb = by_id[a], by_id[b]
        straight = haversine(sa["lat"], sa["lon"], sb["lat"], sb["lon"])
        if straight > 1:
            ratios.append(metres / straight)
    ratios.sort()

    def pct(p):
        return ratios[min(len(ratios) - 1, int(p * len(ratios)))]

    print(f"\npairs written         {len(rows)} -> {args.out}", file=sys.stderr)
    print(f"real/straight ratio   p10 {pct(.10):.2f}  p50 {pct(.50):.2f}  "
          f"p90 {pct(.90):.2f}  max {ratios[-1]:.2f}", file=sys.stderr)
    print(f"elapsed               {time.time() - started:.1f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
