import { ArrowDownIcon, ArrowUpIcon } from "lucide-react";
import type { SidebarSectionKey } from "@t3tools/contracts/settings";
import { Button } from "../ui/button";

const SECTION_LABELS: Record<SidebarSectionKey, string> = {
  working: "Working",
  active: "Pinned and active",
  snoozed: "Snoozed",
  settled: "Settled",
};

export function SidebarSectionOrderControl(props: {
  order: readonly SidebarSectionKey[];
  onChange: (order: SidebarSectionKey[]) => void;
}) {
  const move = (index: number, offset: -1 | 1) => {
    const next = [...props.order];
    const [moved] = next.splice(index, 1);
    if (moved === undefined) return;
    next.splice(index + offset, 0, moved);
    props.onChange(next);
  };

  return (
    <ol aria-label="Sidebar section order" className="w-full space-y-0.5 sm:w-56">
      {props.order.map((key, index) => (
        <li
          key={key}
          className="flex items-center gap-1 rounded-md border border-border/60 py-0.5 pr-0.5 pl-2.5"
        >
          <span className="min-w-0 flex-1 truncate text-sm">{SECTION_LABELS[key]}</span>
          <Button
            variant="ghost-muted"
            size="icon-xs"
            aria-label={`Move ${SECTION_LABELS[key]} up`}
            disabled={index === 0}
            onClick={() => move(index, -1)}
          >
            <ArrowUpIcon />
          </Button>
          <Button
            variant="ghost-muted"
            size="icon-xs"
            aria-label={`Move ${SECTION_LABELS[key]} down`}
            disabled={index === props.order.length - 1}
            onClick={() => move(index, 1)}
          >
            <ArrowDownIcon />
          </Button>
        </li>
      ))}
    </ol>
  );
}
