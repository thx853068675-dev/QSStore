/** Read this tracked field in the controls, never in Index's list builders. */
@Observed
export class HomeVisibility {
  @Track visible: boolean = true;
}
