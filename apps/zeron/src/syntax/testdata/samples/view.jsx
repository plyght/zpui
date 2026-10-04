const view = <main id="x" className={styles.root}>
  <Header title="Hi" onClick={() => setOpen(!open)} />
  {items.map(item => <li key={item.id}>{item.label}</li>)}
</main>;
