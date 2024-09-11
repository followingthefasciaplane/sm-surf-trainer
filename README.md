# Surf Movement Trainer Plugin (WIP)

This project is a **movement trainer plugin** that intends to provides real-time surfing feedback to players. Eventually, it will also include long-term statistical data, helping players identify weak points in their surf.

### MomSurfFix

- **MomSurfFix API versions are on hiatus** for a bit.

I plan to expand the functionality of the [MomSurfFix API](https://github.com/followingthefasciaplane/MomSurfFix-API/tree/master) itself, prior to approaching this implementation. This is the way to go because **MomSurfFix** doesn’t just hook deep engine functions to provide data, it also overrides `TryPlayerMove` entirely. This makes movement on the server **MomSurfFix authoritative**, making it, in my opinion, the best way to get accurate movedata for surf prediction. You will need to use my compiled `momsurffix2.smx` for the API to work.

### Standalone

- In the meantime, I'm working on a **standalone implementation** without external dependencies. 

While it's not easy to explain all the methodology, or how to interpret why I've implemented things the way I have, if you would like to expand on this I suggest reading [this article](https://rampsliders.wiki/doku.php?id=physics:surfsdk13). It's an article I wrote on my wiki that details the fundamental principles behind surfing physics in Source.
