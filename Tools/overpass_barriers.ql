[out:json][timeout:180];
(
  way["highway"="steps"](42.13,-8.83,42.29,-8.61);
  way["wheelchair"="no"]["highway"](42.13,-8.83,42.29,-8.61);
  way["highway"]["incline"~"^(up|down|steep|-?[2-9][0-9](\\.[0-9]+)?%)$"](42.13,-8.83,42.29,-8.61);
);
out ids;
