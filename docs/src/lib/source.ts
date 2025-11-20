import { docs } from "fumadocs-mdx:collections/server";
import { loader } from "fumadocs-core/source";
import * as icons from "lucide-static";

export const source = loader({
  source: docs.toFumadocsSource(),
  baseUrl: "/",
  icon(icon) {
    if (!icon) {
      return;
    }

    // biome-ignore lint/performance/noDynamicNamespaceImportAccess: required
    if (icon in icons) return icons[icon as keyof typeof icons];
  },
});
