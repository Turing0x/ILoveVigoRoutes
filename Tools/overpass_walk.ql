[out:json][timeout:600];
(
  way["highway"]
     ["highway"!~"^(motorway|motorway_link|trunk|trunk_link|construction|proposed|raceway|bus_guideway)$"]
     ["foot"!~"^(no|private)$"]
     ["access"!~"^(no|private)$"]
     (42.13,-8.83,42.29,-8.61);
);
(._;>;);
out skel qt;
