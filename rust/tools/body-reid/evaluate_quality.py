"""Explore post-NMS body quality gates using saved production body_debug output.

Requires numpy, Pillow and matplotlib. Inputs are local Penn-Fudan files and
production JSONL, or ml-timing records.json with repeated warm trials. No model,
app metadata, or production thresholds are changed. See the companion report
for annotation limitations; neither largest nor original implies main subject.
"""

import argparse
import csv
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image, ImageFilter


def iou(a, b):
    intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(
        0, min(a[3], b[3]) - max(a[1], b[1])
    )
    union = ((a[2] - a[0]) * (a[3] - a[1])
             + (b[2] - b[0]) * (b[3] - b[1]) - intersection)
    return intersection / union if union > 0 else 0


def geometry(box, width, height):
    w, h = box[2] - box[0], box[3] - box[1]
    return dict(relative_height=h, relative_width=w, relative_area=w * h,
                pixel_width=w * width, pixel_height=h * height)


def sharpness(crop):
    # Exploratory score, not Ente's aligned-face blur metric. Normalize size so
    # the gate is not merely a proxy for source-image dimensions.
    gray = np.asarray(crop.convert("L").resize((128, 256), Image.Resampling.BILINEAR),
                      dtype=np.float32)
    lap = (gray[:-2, 1:-1] + gray[2:, 1:-1] + gray[1:-1, :-2]
           + gray[1:-1, 2:] - 4 * gray[1:-1, 1:-1])
    return float(lap.var())


def quantiles(values):
    return dict(zip(["min", "p10", "p25", "median", "p75", "p90", "max"],
                    map(float, np.quantile(values, [0, .1, .25, .5, .75, .9, 1]))))


def read_predictions(path):
    text = path.read_text()
    repeated = json.loads(text) if text.lstrip().startswith("[") else [
        json.loads(line) for line in text.splitlines() if line.strip()
    ]
    by_image = defaultdict(list)
    for item in repeated:
        if item.get("warmup", False):
            continue
        row = item.get("image", item)
        by_image[Path(row["path"]).name].append(row)
    result = {}
    for name, rows in sorted(by_image.items()):
        first = rows[0]
        for row in rows[1:]:
            for key in ["width", "height", "faces", "bodies", "model"]:
                if row[key] != first[key]:
                    raise ValueError(f"Repeated inference differs: {name}/{key}")
        result[name] = first
    return result, {name: len(rows) for name, rows in by_image.items()}


def gate(name, score=.4, height=.12, area=0, width_px=0, height_px=0, blur=0,
         protect_face_anchor=False):
    return dict(name=name, score=score, height=height, area=area,
                width_px=width_px, height_px=height_px, blur=blur,
                protect_face_anchor=protect_face_anchor)


def keep(d, g):
    if g["protect_face_anchor"] and d["face_linked"]:
        return True
    return (d["score"] >= g["score"] and d["relative_height"] >= g["height"]
            and d["relative_area"] >= g["area"]
            and d["pixel_width"] >= g["width_px"]
            and d["pixel_height"] >= g["height_px"]
            and d["sharpness"] >= g["blur"])


def match(predictions, annotations):
    used = set()
    matched = {}
    for d in sorted(predictions, key=lambda d: (-d["score"], d["id"])):
        overlap, index = max(
            ((iou(d["box"], a["box"]), i) for i, a in enumerate(annotations)
             if i not in used), default=(0, -1),
        )
        if overlap >= .5:
            used.add(index)
            matched[d["id"]] = annotations[index]["id"]
    return used, matched


def evaluate(photos, g):
    counts = defaultdict(int)
    matched_ids, kept_ids = set(), set()
    for photo in photos:
        gt = photo["annotations"]
        detections = [d for d in photo["detections"] if keep(d, g)]
        used, matched = match(detections, gt)
        counts["boxes"] += len(detections)
        counts["matched"] += len(used)
        counts["unmatched"] += len(detections) - len(used)
        retained = [d for d in detections if d["association_retained"]]
        counts["association_retained"] += len(retained)
        used_faces = set()
        linked_count = 0
        for d in retained:
            face_ids = d["face_ids"]
            if len(face_ids) == 1 and face_ids[0] not in used_faces:
                used_faces.add(face_ids[0])
                linked_count += 1
        counts["face_linked_boxes"] += linked_count
        counts["no_linked_face_boxes"] += len(retained) - linked_count
        counts["ambiguous_multi_face_boxes"] += sum(d["face_count"] > 1 for d in detections)
        retained_used, _ = match(retained, gt)
        counts["association_retained_matched"] += len(retained_used)
        kept_ids.update(d["id"] for d in detections)
        matched_ids.update(gt[i]["id"] for i in used)
        for i, a in enumerate(gt):
            for cohort in ["all", "supplemental" if a["supplemental"] else "original"]:
                counts[f"{cohort}_total"] += 1
                counts[f"{cohort}_matched"] += int(i in used)
            if a["largest"]:
                counts["largest_total"] += 1
                counts["largest_matched"] += int(i in used)
    row = dict(g, **counts)
    for cohort in ["all", "original", "supplemental", "largest"]:
        row[f"{cohort}_recall"] = (counts[f"{cohort}_matched"]
                                    / counts[f"{cohort}_total"])
    row["annotation_match_fraction"] = counts["matched"] / counts["boxes"] if counts["boxes"] else None
    return row, matched_ids, kept_ids


def write_csv(path, rows):
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def verify_matching():
    # One-to-one matching and inclusive IoU boundary are part of the protocol.
    assert iou([0, 0, 1, 1], [0, 0, 1, 1]) == 1
    assert iou([0, 0, .5, 1], [.5, 0, 1, 1]) == 0
    used, assigned = match([
        dict(id="high", score=.9, box=[0, 0, .5, 1]),
        dict(id="duplicate", score=.8, box=[0, 0, .5, 1]),
    ], [dict(id="person", box=[0, 0, 1, 1])])
    assert used == {0} and assigned == {"high": "person"}


def main():
    verify_matching()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    added = set()
    for line in (args.dataset / "added-object-list.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            name, number = line.split()
            added.add((name, int(number)))
    predictions, repeats = read_predictions(args.predictions)
    expected = {p.stem + ".png" for p in (args.dataset / "Annotation").glob("*.txt")}
    if set(predictions) != expected:
        raise ValueError("Predictions must cover every annotated image exactly once")
    photos, all_annotations, all_detections, blur_trials = [], [], [], []
    annotation_hashes = {}
    for name, row in predictions.items():
        path = args.dataset / "Annotation" / (Path(name).stem + ".txt")
        annotation_hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        text = path.read_text()
        w, h = row["width"], row["height"]
        dimensions = re.search(r"Image size.*?: (\d+) x (\d+) x", text)
        assert dimensions and tuple(map(int, dimensions.groups())) == (w, h)
        boxes = re.findall(
            r'Bounding box for object (\d+).*?: \((\d+), (\d+)\) - \((\d+), (\d+)\)', text,
        )
        annotations = []
        for number, x1, y1, x2, y2 in boxes:
            # Dataset documents 1-based inclusive coordinates.
            box = [(int(x1) - 1) / w, (int(y1) - 1) / h, int(x2) / w, int(y2) / h]
            annotations.append(dict(id=f"{name}:{number}", image=name, object=int(number),
                                    box=box, supplemental=(name, int(number)) in added,
                                    **geometry(box, w, h)))
        declared = int(re.search(r"Objects with ground truth : (\d+)", text)[1])
        assert len(annotations) == declared and annotations
        largest_area = max(a["relative_area"] for a in annotations)
        for a in annotations:
            a["largest"] = a["relative_area"] == largest_area
        with Image.open(args.dataset / "PNGImages" / name) as source:
            image = source.convert("RGB")
            detections = []
            used_faces = set()
            for i, d in enumerate(row["bodies"]):
                box = d["box"]
                assert d["embedding_dimensions"] == 512
                assert abs(d["embedding_norm"] - 1) < 1e-5
                assert np.isfinite(d["score"]) and 0 <= d["score"] <= 1
                assert len(box) == 4 and all(np.isfinite(v) and 0 <= v <= 1 for v in box)
                crop = image.crop((int(np.floor(box[0] * w)), int(np.floor(box[1] * h)),
                                   int(np.ceil(box[2] * w)), int(np.ceil(box[3] * h))))
                face_ids = [j for j, f in enumerate(row["faces"])
                            if f["score"] > 0
                            and box[0] <= (f["box"][0] + f["box"][2]) / 2 <= box[2]
                            and box[1] <= (f["box"][1] + f["box"][3]) / 2 <= box[3]]
                face_count = len(face_ids)
                linked = face_count == 1 and face_ids[0] not in used_faces
                if linked:
                    used_faces.add(face_ids[0])
                detections.append(dict(id=f"{name}:d{i}", image=name, box=box,
                                       score=d["score"], sharpness=sharpness(crop),
                                       association_retained=face_count <= 1,
                                       face_count=face_count, face_ids=face_ids, face_linked=linked,
                                       **geometry(box, w, h)))
                for radius in [0, 1, 2, 4]:
                    value = sharpness(crop.filter(ImageFilter.GaussianBlur(radius))) if radius else detections[-1]["sharpness"]
                    blur_trials.append(dict(id=f"{name}:d{i}", radius=radius, sharpness=value))
        photos.append(dict(image=name, annotations=annotations, detections=detections))
        all_annotations.extend(annotations)
        all_detections.extend(detections)
    assert len(added) == sum(a["supplemental"] for a in all_annotations)
    gates = [gate("baseline")]
    gates += [gate(f"score_{s}", score=s) for s in [.45, .5, .55, .6, .7, .8]]
    gates += [gate(f"height_{h}", height=h) for h in [.15, .18, .2, .25, .3]]
    gates += [gate(f"area_{a}", area=a) for a in [.005, .01, .02, .03, .05]]
    gates += [gate(f"pixels_{w}x{h}", width_px=w, height_px=h) for w, h in [(32, 64), (48, 96), (64, 128)]]
    gates += [gate(f"blur_{b}", blur=b) for b in [10, 25, 50, 100, 200, 400]]
    gates += [gate("candidate_protect_anchors", score=.45, height=.15, protect_face_anchor=True),
              gate("candidate_protect_anchors_score05", score=.5, height=.15, protect_face_anchor=True),
              gate("candidate_conservative", score=.45, height=.15),
              gate("candidate_conservative_blur10", score=.45, height=.15, blur=10),
              gate("candidate_score_height", score=.5, height=.15),
              gate("candidate_add_area", score=.5, height=.15, area=.01),
              gate("candidate_add_pixels", score=.5, height=.15, width_px=64, height_px=128),
              gate("candidate_all_size", score=.5, height=.15, area=.01, width_px=64, height_px=128)]
    baseline, baseline_matched, baseline_kept = evaluate(photos, gates[0])
    rows, lost, scale_rows = [], {}, []
    for g in gates:
        result, matched, kept = evaluate(photos, g)
        result["removed_boxes"] = baseline["boxes"] - result["boxes"]
        result["lost_baseline_annotations"] = len(baseline_matched - matched)
        result["box_reduction_fraction"] = result["removed_boxes"] / baseline["boxes"]
        rows.append(result)
        for lo, hi, label in [(0, .01, "<1%"), (.01, .03, "1-3%"),
                               (.03, .1, "3-10%"), (.1, 1.01, ">=10%")]:
            subset = [a for a in all_annotations if lo <= a["relative_area"] < hi]
            hits = sum(a["id"] in matched for a in subset)
            scale_rows.append(dict(gate=g["name"], area_bin=label, annotations=len(subset),
                                   matched=hits, recall=hits / len(subset) if subset else None))
        lost[g["name"]] = dict(annotations=sorted(baseline_matched - matched),
                                detections=sorted(baseline_kept - kept))
    grid = []
    for score in [.4, .5, .6]:
        for height in [.12, .15, .2]:
            for area in [0, .01, .02]:
                for pw, ph in [(0, 0), (32, 64), (64, 128)]:
                    g = gate(f"grid_{score}_{height}_{area}_{pw}_{ph}", score, height, area, pw, ph)
                    result, matched, _ = evaluate(photos, g)
                    result["lost_baseline_annotations"] = len(baseline_matched - matched)
                    grid.append(result)
    cohort_stats = {}
    for name, subset in [
        ("all", all_annotations),
        ("original", [a for a in all_annotations if not a["supplemental"]]),
        ("supplemental", [a for a in all_annotations if a["supplemental"]]),
        ("largest_per_image_proxy", [a for a in all_annotations if a["largest"]]),
    ]:
        cohort_stats[name] = dict(count=len(subset), **{
            k: quantiles([a[k] for a in subset]) for k in
            ["relative_area", "relative_height", "pixel_width", "pixel_height"]
        })
    splits = {prefix: [evaluate([p for p in photos if p["image"].startswith(prefix)], g)[0]
                       for g in gates] for prefix in ["Penn", "Fudan"]}
    for name, data in [("thresholds", rows), ("grid", grid), ("annotations", all_annotations),
                       ("detections", all_detections), ("blur_trials", blur_trials)]:
        (args.output / f"{name}.json").write_text(json.dumps(data, indent=2) + "\n")
    for name, data in [("thresholds", rows), ("grid", grid), ("scale_bins", scale_rows)]:
        write_csv(args.output / f"{name}.csv", data)
    face_rows = []
    for g in gates:
        for cohort, select in [
            ("face_linked", lambda d: d["face_linked"]),
            ("no_linked_face", lambda d: d["association_retained"] and not d["face_linked"]),
            ("multiple_faces_excluded", lambda d: d["face_count"] > 1),
        ]:
            baseline_group = [d for d in all_detections if select(d)]
            kept_group = [d for d in baseline_group if keep(d, g)]
            face_rows.append(dict(gate=g["name"], cohort=cohort, baseline=len(baseline_group),
                                  kept=len(kept_group), removed=len(baseline_group)-len(kept_group)))
    write_csv(args.output / "face_association.csv", face_rows)
    (args.output / "lost_samples.json").write_text(json.dumps(lost, indent=2) + "\n")
    blur_sensitivity = []
    for radius in [0, 1, 2, 4]:
        values = [r["sharpness"] for r in blur_trials if r["radius"] == radius]
        blur_sensitivity.append(dict(radius=radius, quantiles=quantiles(values),
                                     below_10=sum(v < 10 for v in values),
                                     below_25=sum(v < 25 for v in values)))
    write_csv(args.output / "blur_sensitivity.csv", [dict(radius=r["radius"],
              median=r["quantiles"]["median"], below_10=r["below_10"],
              below_25=r["below_25"]) for r in blur_sensitivity])
    summary = dict(blur_sensitivity=blur_sensitivity, images=len(photos), annotation_count=len(all_annotations),
                   supplemental_count=len(added), detection_count=len(all_detections),
                   repeated_trials=repeats, baseline=baseline, cohorts=cohort_stats,
                   subsets=splits,
                   predictions_sha256=hashlib.sha256(args.predictions.read_bytes()).hexdigest(),
                   annotation_hashes=annotation_hashes)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    fig, axes = plt.subplots(1, 3, figsize=(15, 4))
    for name, subset in [("Original annotations", [a for a in all_annotations if not a["supplemental"]]),
                         ("Supplemental small/occluded", [a for a in all_annotations if a["supplemental"]])]:
        for ax, key, label in [(axes[0], "relative_height", "Box height / image height"),
                               (axes[1], "relative_area", "Box area / image area")]:
            values = np.sort([a[key] for a in subset])
            ax.plot(values * 100, np.arange(1, len(values) + 1) / len(values), label=f"{name} (n={len(values)})")
            ax.set_xlabel(label + " (%)")
            ax.set_ylabel("Cumulative fraction")
            ax.grid(alpha=.2)
    axes[1].legend(fontsize=8)
    for prefix, label in [("score_", "Confidence"), ("height_", "Relative height"),
                           ("area_", "Relative area"), ("pixels_", "Pixel size"), ("blur_", "Sharpness")]:
        selected = [r for r in rows if r["name"].startswith(prefix)]
        axes[2].plot([r["box_reduction_fraction"] * 100 for r in selected],
                     [r["original_recall"] * 100 for r in selected], "o-", label=label)
    axes[2].set_xlabel("Raw detections removed (%)")
    axes[2].set_ylabel("Original-annotation recall (%)")
    axes[2].grid(alpha=.2)
    axes[2].legend(fontsize=8)
    fig.suptitle("Penn-Fudan: body size distributions and quality-filter trade-offs")
    fig.tight_layout()
    fig.savefig(args.output / "quality-gates.png", dpi=160)
    plt.close(fig)
    print(json.dumps(dict(images=len(photos), annotations=len(all_annotations),
                          supplemental=len(added), baseline=baseline), indent=2))


if __name__ == "__main__":
    main()
