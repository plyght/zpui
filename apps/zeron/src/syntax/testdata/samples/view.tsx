import React, { useState } from "react";
type Props = { title: string; count?: number };
export function Card({ title, count = 0 }: Props): JSX.Element {
  const [open, setOpen] = useState<boolean>(false);
  return <div className="card" onClick={() => setOpen(!open)}>{title}: {count}</div>;
}
